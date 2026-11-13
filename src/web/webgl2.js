// WebGL2 browser backend implementing the Knots GPU device/queue/surface contract.

const BUFFER_USAGE_INDEX = 16;
const BUFFER_USAGE_UNIFORM = 64;
const BUFFER_USAGE_STORAGE = 128;
const MIN_UBO_BACKING_BYTES = 16384;
const STORAGE_TEX_WIDTH = 1024;

function textureFormatInfo(gl, format) {
  switch (format) {
    case "rgba8unorm":
    case "bgra8unorm":
      return {
        internalFormat: gl.RGBA8,
        format: gl.RGBA,
        type: gl.UNSIGNED_BYTE,
        bytesPerPixel: 4,
        arrayType: "u8",
      };
    case "rgba8unorm-srgb":
    case "bgra8unorm-srgb":
      return {
        internalFormat: gl.SRGB8_ALPHA8,
        format: gl.RGBA,
        type: gl.UNSIGNED_BYTE,
        bytesPerPixel: 4,
        arrayType: "u8",
      };
    case "r8unorm":
      return {
        internalFormat: gl.R8,
        format: gl.RED,
        type: gl.UNSIGNED_BYTE,
        bytesPerPixel: 1,
        arrayType: "u8",
      };
    case "rgba32float":
      return {
        internalFormat: gl.RGBA32F,
        format: gl.RGBA,
        type: gl.FLOAT,
        bytesPerPixel: 16,
        arrayType: "f32",
      };
    case "rgba32uint":
      return {
        internalFormat: gl.RGBA32UI,
        format: gl.RGBA_INTEGER,
        type: gl.UNSIGNED_INT,
        bytesPerPixel: 16,
        arrayType: "u32",
      };
    case "depth24plus":
      return {
        internalFormat: gl.DEPTH_COMPONENT24,
        format: gl.DEPTH_COMPONENT,
        type: gl.UNSIGNED_INT,
        bytesPerPixel: 4,
        arrayType: "u32",
      };
    default:
      throw new Error(`Unsupported WebGL2 texture format: ${format}`);
  }
}

function vertexFormatInfo(gl, format) {
  switch (format) {
    case "float32":
      return { components: 1, type: gl.FLOAT, isInteger: false };
    case "float32x2":
      return { components: 2, type: gl.FLOAT, isInteger: false };
    case "float32x3":
      return { components: 3, type: gl.FLOAT, isInteger: false };
    case "float32x4":
      return { components: 4, type: gl.FLOAT, isInteger: false };
    case "uint32":
      return { components: 1, type: gl.UNSIGNED_INT, isInteger: true };
    case "float16x4":
      return { components: 4, type: gl.HALF_FLOAT, isInteger: false };
    default:
      throw new Error(`Unsupported WebGL2 vertex format: ${format}`);
  }
}

function glBlendFactor(gl, factor) {
  switch (factor) {
    case "zero":
      return gl.ZERO;
    case "one":
      return gl.ONE;
    case "src-alpha":
      return gl.SRC_ALPHA;
    case "one-minus-src-alpha":
      return gl.ONE_MINUS_SRC_ALPHA;
    default:
      return gl.ONE;
  }
}

function glBlendOp(gl, op) {
  switch (op) {
    case "add":
    default:
      return gl.FUNC_ADD;
  }
}

function glCompareFunc(gl, compare) {
  switch (compare) {
    case "less":
      return gl.LESS;
    case "less-equal":
      return gl.LEQUAL;
    case "always":
    default:
      return gl.ALWAYS;
  }
}

function glFilterMode(gl, mode) {
  return mode === "linear" ? gl.LINEAR : gl.NEAREST;
}

function glAddressMode(gl, mode) {
  switch (mode) {
    case "repeat":
      return gl.REPEAT;
    case "mirror-repeat":
      return gl.MIRRORED_REPEAT;
    case "clamp-to-edge":
    default:
      return gl.CLAMP_TO_EDGE;
  }
}

function injectFragmentDefines(source, entryPoint) {
  if (entryPoint !== "fs_main_srgb_encode") return source;
  const newline = source.indexOf("\n");
  if (newline === -1) return source;
  return `${source.slice(0, newline + 1)}#define SRGB_ENCODE 1\n${source.slice(newline + 1)}`;
}

function compileShader(gl, type, source, label) {
  const shader = gl.createShader(type);
  if (!shader) throw new Error(`Failed to allocate WebGL2 shader (${label})`);
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
    const info = gl.getShaderInfoLog(shader) || "unknown shader compile error";
    gl.deleteShader(shader);
    throw new Error(`WebGL2 shader compile failed (${label}): ${info}`);
  }
  return shader;
}

function linkProgram(gl, vsSource, fsSource, label) {
  const vs = compileShader(gl, gl.VERTEX_SHADER, vsSource, `${label}:vs`);
  let fs;
  try {
    fs = compileShader(gl, gl.FRAGMENT_SHADER, fsSource, `${label}:fs`);
  } catch (err) {
    gl.deleteShader(vs);
    throw err;
  }
  const program = gl.createProgram();
  if (!program) {
    gl.deleteShader(vs);
    gl.deleteShader(fs);
    throw new Error(`Failed to allocate WebGL2 program (${label})`);
  }
  gl.attachShader(program, vs);
  gl.attachShader(program, fs);
  gl.linkProgram(program);
  gl.deleteShader(vs);
  gl.deleteShader(fs);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
    const info = gl.getProgramInfoLog(program) || "unknown program link error";
    gl.deleteProgram(program);
    throw new Error(`WebGL2 program link failed (${label}): ${info}`);
  }
  return program;
}

class WebGL2RenderPass {
  constructor(backend, desc) {
    this.backend = backend;
    this.gl = backend.gl;
    this.desc = desc;
    this.pipeline = null;
    this.bindGroups = [];
    this.vertexBuffers = [];
    this.indexBuffer = null;
    this.begin();
  }

  begin() {
    const { gl, backend, desc } = this;
    const colorAtt = desc.colorAttachments?.[0];
    const depthAtt = desc.depthStencilAttachment ?? null;
    const targetView = colorAtt?.view;
    if (!targetView) throw new Error("WebGL2 render pass is missing a color attachment view");

    const fbo = backend.getOrCreateFramebuffer(targetView, depthAtt?.view ?? null);
    gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);

    if (targetView.isSurface) {
      backend.surfaceDirty = true;
    }

    const width = targetView.texture.width;
    const height = targetView.texture.height;
    this.targetWidth = width;
    this.targetHeight = height;

    // Clear operations must not be clipped by a previous pass's scissor or depthMask.
    gl.disable(gl.SCISSOR_TEST);
    gl.colorMask(true, true, true, true);

    let clearMask = 0;
    if (colorAtt.loadOp === "clear") {
      const c = colorAtt.clearValue ?? { r: 0, g: 0, b: 0, a: 1 };
      gl.clearColor(c.r ?? 0, c.g ?? 0, c.b ?? 0, c.a ?? 1);
      clearMask |= gl.COLOR_BUFFER_BIT;
    }
    if (depthAtt && depthAtt.depthLoadOp === "clear") {
      gl.depthMask(true);
      gl.clearDepth(depthAtt.depthClearValue ?? 1.0);
      clearMask |= gl.DEPTH_BUFFER_BIT;
    }
    if (clearMask !== 0) {
      gl.clear(clearMask);
    }

    gl.viewport(0, 0, width, height);
    gl.enable(gl.SCISSOR_TEST);
    gl.scissor(0, 0, width, height);
  }

  setPipeline(pipeline) {
    this.pipeline = pipeline;
  }

  setBindGroup(groupIndex, bindGroup) {
    this.bindGroups[groupIndex] = bindGroup;
  }

  setVertexBuffer(slot, buffer, offset = 0, size = 0) {
    this.vertexBuffers[slot] = { buffer, offset, size };
  }

  setIndexBuffer(buffer, format, offset = 0, size = 0) {
    this.indexBuffer = { buffer, format, offset, size };
  }

  setViewport(x, y, width, height) {
    this.gl.viewport(Math.round(x), Math.round(y), Math.round(width), Math.round(height));
  }

  setScissorRect(x, y, width, height) {
    this.gl.scissor(Math.round(x), Math.round(y), Math.round(width), Math.round(height));
  }

  applyState(baseVertex, firstInstance) {
    const { gl, pipeline } = this;
    if (!pipeline) throw new Error("WebGL2 draw called without an active pipeline");

    gl.useProgram(pipeline.program);

    // Blend state
    if (pipeline.blend) {
      gl.enable(gl.BLEND);
      gl.blendFuncSeparate(
        pipeline.blend.colorSrc,
        pipeline.blend.colorDst,
        pipeline.blend.alphaSrc,
        pipeline.blend.alphaDst,
      );
      gl.blendEquationSeparate(pipeline.blend.colorOp, pipeline.blend.alphaOp);
    } else {
      gl.disable(gl.BLEND);
    }

    // Depth state
    if (pipeline.depthStencil && this.desc.depthStencilAttachment) {
      gl.enable(gl.DEPTH_TEST);
      gl.depthFunc(pipeline.depthStencil.compare);
      gl.depthMask(pipeline.depthStencil.writeEnabled);
    } else {
      gl.disable(gl.DEPTH_TEST);
      gl.depthMask(false);
    }

    // Cull & front-face state. Because our GLSL vertex shaders negate clip Y to render
    // top-down into FBOs, winding orientation is mirrored relative to WebGPU's Y-up clip space.
    if (pipeline.cullMode === "back") {
      gl.enable(gl.CULL_FACE);
      gl.cullFace(gl.BACK);
      gl.frontFace(pipeline.frontFace === "cw" ? gl.CCW : gl.CW);
    } else {
      gl.disable(gl.CULL_FACE);
    }

    // Bind groups (UBOs, storage UBOs, textures, samplers)
    for (let groupIndex = 0; groupIndex < pipeline.bindGroupLayouts.length; groupIndex++) {
      const bindGroup = this.bindGroups[groupIndex];
      if (!bindGroup) continue;
      let groupSampler = null;
      for (const entry of bindGroup.entries) {
        if (entry.resource?.glSampler) {
          groupSampler = entry.resource.glSampler;
          break;
        }
      }

      for (const entry of bindGroup.entries) {
        const key = `${groupIndex}:${entry.binding}`;
        const res = entry.resource;
        if (!res) continue;

        if (res.buffer && res.buffer.glBuffer) {
          const uboSlot = pipeline.uboBindings.get(key);
          if (uboSlot !== undefined) {
            const offset = res.offset ?? 0;
            if (offset === 0) {
              gl.bindBufferBase(gl.UNIFORM_BUFFER, uboSlot, res.buffer.glBuffer);
            } else {
              const bindSize = Math.min(
                Math.max(res.size ?? 0, MIN_UBO_BACKING_BYTES),
                res.buffer.allocSize - offset,
              );
              gl.bindBufferRange(gl.UNIFORM_BUFFER, uboSlot, res.buffer.glBuffer, offset, bindSize);
            }
          }
          const storageTexUnit = pipeline.storageTexBindings.get(key);
          if (storageTexUnit !== undefined) {
            const glTex = this.backend.ensureStorageTexture(res.buffer);
            gl.activeTexture(gl.TEXTURE0 + storageTexUnit);
            gl.bindTexture(gl.TEXTURE_2D, glTex);
            gl.bindSampler(storageTexUnit, null);
          }
        } else if (res.texture && res.texture.glTexture) {
          const texUnit = pipeline.textureBindings.get(key);
          if (texUnit !== undefined) {
            gl.activeTexture(gl.TEXTURE0 + texUnit);
            gl.bindTexture(gl.TEXTURE_2D, res.texture.glTexture);
            gl.bindSampler(texUnit, groupSampler);
          }
        }
      }
    }

    // Vertex Array & attributes
    gl.bindVertexArray(pipeline.vao);
    for (let slot = 0; slot < pipeline.vertexBuffers.length; slot++) {
      const vbLayout = pipeline.vertexBuffers[slot];
      const vb = this.vertexBuffers[slot];
      if (!vb || !vb.buffer?.glBuffer) continue;

      gl.bindBuffer(gl.ARRAY_BUFFER, vb.buffer.glBuffer);
      const isInstanced = vbLayout.stepMode === "instance";
      const stepIndex = isInstanced ? firstInstance : baseVertex;
      const baseOffset = vb.offset + stepIndex * vbLayout.arrayStride;

      for (const attr of vbLayout.attributes) {
        gl.enableVertexAttribArray(attr.shaderLocation);
        if (attr.isInteger) {
          gl.vertexAttribIPointer(
            attr.shaderLocation,
            attr.components,
            attr.type,
            vbLayout.arrayStride,
            baseOffset + attr.offset,
          );
        } else {
          gl.vertexAttribPointer(
            attr.shaderLocation,
            attr.components,
            attr.type,
            false,
            vbLayout.arrayStride,
            baseOffset + attr.offset,
          );
        }
        gl.vertexAttribDivisor(attr.shaderLocation, isInstanced ? 1 : 0);
      }
    }
  }

  draw(vertexCount, instanceCount = 1, firstVertex = 0, firstInstance = 0) {
    if (vertexCount === 0 || instanceCount === 0) return;
    this.applyState(0, firstInstance);
    this.gl.drawArraysInstanced(this.gl.TRIANGLES, firstVertex, vertexCount, instanceCount);
  }

  drawIndexed(indexCount, instanceCount = 1, firstIndex = 0, baseVertex = 0, firstInstance = 0) {
    if (indexCount === 0 || instanceCount === 0) return;
    if (!this.indexBuffer?.buffer?.glBuffer) {
      throw new Error("WebGL2 drawIndexed called without an index buffer");
    }
    this.applyState(baseVertex, firstInstance);
    const { gl } = this;
    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, this.indexBuffer.buffer.glBuffer);
    const byteOffset = this.indexBuffer.offset + firstIndex * 4;
    gl.drawElementsInstanced(gl.TRIANGLES, indexCount, gl.UNSIGNED_INT, byteOffset, instanceCount);
  }

  end() {
    this.gl.bindVertexArray(null);
  }
}

export function createWebGL2Backend(initialCanvas) {
  let gl = null;
  let boundCanvas = null;

  function ensureGl(canvas) {
    if (gl) return gl;
    const target = canvas ?? initialCanvas;
    if (!target) throw new Error("WebGL2 backend requires an HTMLCanvasElement");
    const ctx = target.getContext("webgl2", {
      alpha: true,
      depth: false,
      stencil: false,
      antialias: false,
      premultipliedAlpha: true,
      preserveDrawingBuffer: false,
    });
    if (!ctx) {
      throw new Error("WebGL2 context creation failed (webgl2 is unavailable or disabled)");
    }
    gl = ctx;
    boundCanvas = target;
    return gl;
  }

  if (initialCanvas) {
    ensureGl(initialCanvas);
  }

  const backend = {
    get gl() {
      return ensureGl();
    },
    surfaceTexture: null,
    surfaceView: null,
    surfaceFbo: null,
    surfaceDirty: false,
    surfaceWidth: 0,
    surfaceHeight: 0,

    ensureSurfaceTarget(width, height, format) {
      const ctx = this.gl;
      const w = Math.max(1, width | 0);
      const h = Math.max(1, height | 0);
      if (this.surfaceTexture && this.surfaceWidth === w && this.surfaceHeight === h) {
        return;
      }
      this.destroySurfaceTarget();
      const glTex = ctx.createTexture();
      ctx.bindTexture(ctx.TEXTURE_2D, glTex);
      ctx.texParameteri(ctx.TEXTURE_2D, ctx.TEXTURE_BASE_LEVEL, 0);
      ctx.texParameteri(ctx.TEXTURE_2D, ctx.TEXTURE_MAX_LEVEL, 0);
      ctx.texParameteri(ctx.TEXTURE_2D, ctx.TEXTURE_MIN_FILTER, ctx.NEAREST);
      ctx.texParameteri(ctx.TEXTURE_2D, ctx.TEXTURE_MAG_FILTER, ctx.NEAREST);
      ctx.texParameteri(ctx.TEXTURE_2D, ctx.TEXTURE_WRAP_S, ctx.CLAMP_TO_EDGE);
      ctx.texParameteri(ctx.TEXTURE_2D, ctx.TEXTURE_WRAP_T, ctx.CLAMP_TO_EDGE);
      ctx.texStorage2D(ctx.TEXTURE_2D, 1, ctx.RGBA8, w, h);
      ctx.bindTexture(ctx.TEXTURE_2D, null);

      const fbo = ctx.createFramebuffer();
      ctx.bindFramebuffer(ctx.FRAMEBUFFER, fbo);
      ctx.framebufferTexture2D(ctx.FRAMEBUFFER, ctx.COLOR_ATTACHMENT0, ctx.TEXTURE_2D, glTex, 0);
      ctx.bindFramebuffer(ctx.FRAMEBUFFER, null);

      const texObj = {
        glTexture: glTex,
        fbo,
        attachedDepth: null,
        width: w,
        height: h,
        format: format || "rgba8unorm",
        isSurface: true,
        createView() {
          return backend.surfaceView;
        },
        destroy() {},
      };
      this.surfaceTexture = texObj;
      this.surfaceView = { texture: texObj, isSurface: true };
      this.surfaceFbo = fbo;
      this.surfaceWidth = w;
      this.surfaceHeight = h;
    },

    destroySurfaceTarget() {
      if (!gl) return;
      if (this.surfaceFbo) {
        gl.deleteFramebuffer(this.surfaceFbo);
        this.surfaceFbo = null;
      }
      if (this.surfaceTexture?.glTexture) {
        gl.deleteTexture(this.surfaceTexture.glTexture);
      }
      this.surfaceTexture = null;
      this.surfaceView = null;
      this.surfaceWidth = 0;
      this.surfaceHeight = 0;
    },

    getOrCreateFramebuffer(colorView, depthView) {
      const ctx = this.gl;
      const tex = colorView.texture;
      if (!tex.fbo) {
        tex.fbo = ctx.createFramebuffer();
        ctx.bindFramebuffer(ctx.FRAMEBUFFER, tex.fbo);
        ctx.framebufferTexture2D(
          ctx.FRAMEBUFFER,
          ctx.COLOR_ATTACHMENT0,
          ctx.TEXTURE_2D,
          tex.glTexture,
          0,
        );
      } else {
        ctx.bindFramebuffer(ctx.FRAMEBUFFER, tex.fbo);
      }

      const nextDepth = depthView?.texture?.glTexture ?? null;
      if (tex.attachedDepth !== nextDepth) {
        ctx.framebufferTexture2D(
          ctx.FRAMEBUFFER,
          ctx.DEPTH_ATTACHMENT,
          ctx.TEXTURE_2D,
          nextDepth,
          0,
        );
        tex.attachedDepth = nextDepth;
      }
      return tex.fbo;
    },

    presentSurface() {
      if (!this.surfaceDirty || !this.surfaceFbo || !gl) return;
      this.surfaceDirty = false;
      const w = this.surfaceWidth;
      const h = this.surfaceHeight;
      gl.disable(gl.SCISSOR_TEST);
      gl.bindFramebuffer(gl.READ_FRAMEBUFFER, this.surfaceFbo);
      gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, null);
      // Blit top-left surfaceFbo (y: 0..h) to bottom-left HTMLCanvasElement default framebuffer (y: h..0).
      gl.blitFramebuffer(0, 0, w, h, 0, h, w, 0, gl.COLOR_BUFFER_BIT, gl.NEAREST);
      gl.bindFramebuffer(gl.READ_FRAMEBUFFER, null);
    },

    ensureStorageTexture(buffer) {
      const ctx = this.gl;
      const byteLen = buffer.cpuBytes?.byteLength ?? 0;
      const wordCount = Math.max(1, Math.ceil(byteLen / 4));
      const height = Math.max(1, Math.ceil(wordCount / STORAGE_TEX_WIDTH));
      const requiredBytes = STORAGE_TEX_WIDTH * height * 4;
      if (!buffer.cpuBytes || buffer.cpuBytes.byteLength < requiredBytes) {
        const grown = new Uint8Array(requiredBytes);
        if (buffer.cpuBytes) grown.set(buffer.cpuBytes);
        buffer.cpuBytes = grown;
      }
      if (!buffer.storageTex || buffer.storageTexHeight !== height) {
        if (buffer.storageTex) ctx.deleteTexture(buffer.storageTex);
        const tex = ctx.createTexture();
        ctx.bindTexture(ctx.TEXTURE_2D, tex);
        ctx.texParameteri(ctx.TEXTURE_2D, ctx.TEXTURE_BASE_LEVEL, 0);
        ctx.texParameteri(ctx.TEXTURE_2D, ctx.TEXTURE_MAX_LEVEL, 0);
        ctx.texParameteri(ctx.TEXTURE_2D, ctx.TEXTURE_MIN_FILTER, ctx.NEAREST);
        ctx.texParameteri(ctx.TEXTURE_2D, ctx.TEXTURE_MAG_FILTER, ctx.NEAREST);
        ctx.texParameteri(ctx.TEXTURE_2D, ctx.TEXTURE_WRAP_S, ctx.CLAMP_TO_EDGE);
        ctx.texParameteri(ctx.TEXTURE_2D, ctx.TEXTURE_WRAP_T, ctx.CLAMP_TO_EDGE);
        ctx.texStorage2D(ctx.TEXTURE_2D, 1, ctx.R32UI, STORAGE_TEX_WIDTH, height);
        ctx.bindTexture(ctx.TEXTURE_2D, null);
        buffer.storageTex = tex;
        buffer.storageTexHeight = height;
        buffer.storageTexDirty = true;
      }
      if (buffer.storageTexDirty) {
        const wordsView = new Uint32Array(
          buffer.cpuBytes.buffer,
          buffer.cpuBytes.byteOffset,
          STORAGE_TEX_WIDTH * height,
        );
        ctx.bindTexture(ctx.TEXTURE_2D, buffer.storageTex);
        ctx.pixelStorei(ctx.UNPACK_ALIGNMENT, 4);
        ctx.pixelStorei(ctx.UNPACK_ROW_LENGTH, 0);
        ctx.texSubImage2D(
          ctx.TEXTURE_2D,
          0,
          0,
          0,
          STORAGE_TEX_WIDTH,
          height,
          ctx.RED_INTEGER,
          ctx.UNSIGNED_INT,
          wordsView,
        );
        ctx.bindTexture(ctx.TEXTURE_2D, null);
        buffer.storageTexDirty = false;
      }
      return buffer.storageTex;
    },

    getCanvasContext(canvas) {
      ensureGl(canvas);
      return {
        configure(desc) {
          const w = (canvas ?? boundCanvas)?.width || 1;
          const h = (canvas ?? boundCanvas)?.height || 1;
          backend.ensureSurfaceTarget(w, h, desc?.format ?? "rgba8unorm");
        },
        getCurrentTexture() {
          const w = (canvas ?? boundCanvas)?.width || 1;
          const h = (canvas ?? boundCanvas)?.height || 1;
          backend.ensureSurfaceTarget(w, h, "rgba8unorm");
          return backend.surfaceTexture;
        },
        unconfigure() {
          backend.destroySurfaceTarget();
        },
      };
    },
  };

  const queue = {
    writeBuffer(buffer, offset, dataBytes) {
      const ctx = backend.gl;
      const target = buffer.isIndex ? ctx.ELEMENT_ARRAY_BUFFER : ctx.ARRAY_BUFFER;
      ctx.bindBuffer(target, buffer.glBuffer);
      ctx.bufferSubData(target, offset, dataBytes);
      ctx.bindBuffer(target, null);
      if (buffer.isStorage) {
        const needed = offset + dataBytes.byteLength;
        if (!buffer.cpuBytes || buffer.cpuBytes.byteLength < needed) {
          const aligned = Math.ceil(Math.max(needed, 4) / 4) * 4;
          const next = new Uint8Array(aligned);
          if (buffer.cpuBytes) next.set(buffer.cpuBytes);
          buffer.cpuBytes = next;
        }
        buffer.cpuBytes.set(dataBytes, offset);
        buffer.storageTexDirty = true;
      }
    },

    writeTexture(dest, dataBytes, layout, size) {
      const ctx = backend.gl;
      const tex = dest.texture;
      const info = tex.formatInfo;
      const bytesPerRow = layout.bytesPerRow || size.width * info.bytesPerPixel;
      const rowLength = Math.floor(bytesPerRow / info.bytesPerPixel);

      let uploadView = dataBytes;
      if (info.arrayType === "f32") {
        uploadView =
          dataBytes.byteOffset % 4 === 0
            ? new Float32Array(
                dataBytes.buffer,
                dataBytes.byteOffset,
                Math.floor(dataBytes.byteLength / 4),
              )
            : new Float32Array(dataBytes.slice().buffer);
      } else if (info.arrayType === "u32") {
        uploadView =
          dataBytes.byteOffset % 4 === 0
            ? new Uint32Array(
                dataBytes.buffer,
                dataBytes.byteOffset,
                Math.floor(dataBytes.byteLength / 4),
              )
            : new Uint32Array(dataBytes.slice().buffer);
      }

      ctx.bindTexture(ctx.TEXTURE_2D, tex.glTexture);
      ctx.pixelStorei(ctx.UNPACK_ALIGNMENT, 1);
      ctx.pixelStorei(ctx.UNPACK_ROW_LENGTH, rowLength === size.width ? 0 : rowLength);
      ctx.texSubImage2D(
        ctx.TEXTURE_2D,
        dest.mipLevel ?? 0,
        dest.origin?.x ?? 0,
        dest.origin?.y ?? 0,
        size.width,
        size.height,
        info.format,
        info.type,
        uploadView,
      );
      ctx.pixelStorei(ctx.UNPACK_ROW_LENGTH, 0);
      ctx.bindTexture(ctx.TEXTURE_2D, null);
    },

    submit() {
      backend.presentSurface();
    },
  };

  const device = {
    queue,

    createBuffer(desc) {
      const ctx = backend.gl;
      const usage = desc.usage ?? 0;
      const isIndex = (usage & BUFFER_USAGE_INDEX) !== 0;
      const isStorage = (usage & BUFFER_USAGE_STORAGE) !== 0;
      const isUbo = (usage & (BUFFER_USAGE_UNIFORM | BUFFER_USAGE_STORAGE)) !== 0;
      const allocSize = isUbo
        ? Math.max(desc.size + MIN_UBO_BACKING_BYTES, MIN_UBO_BACKING_BYTES)
        : Math.max(desc.size, 16);
      const target = isIndex ? ctx.ELEMENT_ARRAY_BUFFER : ctx.ARRAY_BUFFER;
      const glBuffer = ctx.createBuffer();
      if (!glBuffer) throw new Error(`Failed to create WebGL2 buffer (${desc.label ?? ""})`);
      ctx.bindBuffer(target, glBuffer);
      ctx.bufferData(target, allocSize, ctx.DYNAMIC_DRAW);
      ctx.bindBuffer(target, null);
      const alignedBytes = Math.ceil(Math.max(desc.size ?? 4, 4) / 4) * 4;
      const bufObj = {
        glBuffer,
        size: desc.size,
        allocSize,
        usage,
        isIndex,
        isStorage,
        cpuBytes: isStorage ? new Uint8Array(alignedBytes) : null,
        storageTex: null,
        storageTexHeight: 0,
        storageTexDirty: true,
        destroy() {
          if (bufObj.storageTex) {
            ctx.deleteTexture(bufObj.storageTex);
            bufObj.storageTex = null;
          }
          ctx.deleteBuffer(glBuffer);
        },
      };
      return bufObj;
    },

    createTexture(desc) {
      const ctx = backend.gl;
      const width = Math.max(1, desc.size?.width ?? 1);
      const height = Math.max(1, desc.size?.height ?? 1);
      const format = desc.format ?? "rgba8unorm";
      const formatInfo = textureFormatInfo(ctx, format);
      const glTexture = ctx.createTexture();
      if (!glTexture) throw new Error(`Failed to create WebGL2 texture (${desc.label ?? ""})`);

      ctx.bindTexture(ctx.TEXTURE_2D, glTexture);
      ctx.texParameteri(ctx.TEXTURE_2D, ctx.TEXTURE_BASE_LEVEL, 0);
      ctx.texParameteri(ctx.TEXTURE_2D, ctx.TEXTURE_MAX_LEVEL, 0);
      ctx.texParameteri(ctx.TEXTURE_2D, ctx.TEXTURE_MIN_FILTER, ctx.NEAREST);
      ctx.texParameteri(ctx.TEXTURE_2D, ctx.TEXTURE_MAG_FILTER, ctx.NEAREST);
      ctx.texParameteri(ctx.TEXTURE_2D, ctx.TEXTURE_WRAP_S, ctx.CLAMP_TO_EDGE);
      ctx.texParameteri(ctx.TEXTURE_2D, ctx.TEXTURE_WRAP_T, ctx.CLAMP_TO_EDGE);
      ctx.texStorage2D(ctx.TEXTURE_2D, 1, formatInfo.internalFormat, width, height);
      ctx.bindTexture(ctx.TEXTURE_2D, null);

      const texObj = {
        glTexture,
        fbo: null,
        attachedDepth: null,
        width,
        height,
        format,
        formatInfo,
        isSurface: false,
        createView() {
          return { texture: texObj, isSurface: false };
        },
        destroy() {
          if (texObj.fbo) {
            ctx.deleteFramebuffer(texObj.fbo);
            texObj.fbo = null;
          }
          ctx.deleteTexture(glTexture);
        },
      };
      return texObj;
    },

    createSampler(desc) {
      const ctx = backend.gl;
      const glSampler = ctx.createSampler();
      if (!glSampler) throw new Error(`Failed to create WebGL2 sampler (${desc?.label ?? ""})`);
      ctx.samplerParameteri(glSampler, ctx.TEXTURE_MAG_FILTER, glFilterMode(ctx, desc?.magFilter));
      ctx.samplerParameteri(glSampler, ctx.TEXTURE_MIN_FILTER, glFilterMode(ctx, desc?.minFilter));
      ctx.samplerParameteri(
        glSampler,
        ctx.TEXTURE_WRAP_S,
        glAddressMode(ctx, desc?.addressModeU),
      );
      ctx.samplerParameteri(
        glSampler,
        ctx.TEXTURE_WRAP_T,
        glAddressMode(ctx, desc?.addressModeV),
      );
      return {
        glSampler,
        destroy() {
          ctx.deleteSampler(glSampler);
        },
      };
    },

    createShaderModule(desc) {
      if (!desc?.glsl?.vs || !desc?.glsl?.fs) {
        throw new Error(
          "Pipeline shader module is missing GLSL ES 3.00 source required by the WebGL2 backend",
        );
      }
      return {
        glsl: desc.glsl,
      };
    },

    createBindGroupLayout(desc) {
      return {
        label: desc?.label ?? "",
        entries: desc?.entries ?? [],
      };
    },

    createPipelineLayout(desc) {
      return {
        label: desc?.label ?? "",
        bindGroupLayouts: desc?.bindGroupLayouts ?? [],
      };
    },

    createRenderPipeline(desc) {
      const ctx = backend.gl;
      const label = desc?.label || "render_pipeline";
      const vsModule = desc.vertex?.module;
      const fsModule = desc.fragment?.module ?? vsModule;
      const vsSource = vsModule?.glsl?.vs;
      const rawFsSource = fsModule?.glsl?.fs;
      if (!vsSource || !rawFsSource) {
        throw new Error(`RenderPipeline '${label}' is missing GLSL ES 3.00 vertex/fragment shaders`);
      }
      const fsSource = injectFragmentDefines(rawFsSource, desc.fragment?.entryPoint);
      const program = linkProgram(ctx, vsSource, fsSource, label);

      const bindGroupLayouts = desc.layout?.bindGroupLayouts ?? [];
      const uboBindings = new Map();
      const storageTexBindings = new Map();
      const textureBindings = new Map();
      let nextUboSlot = 0;
      let nextTexUnit = 0;

      ctx.useProgram(program);
      for (let groupIndex = 0; groupIndex < bindGroupLayouts.length; groupIndex++) {
        const bgl = bindGroupLayouts[groupIndex];
        for (const entry of bgl.entries ?? []) {
          const key = `${groupIndex}:${entry.binding}`;
          const canonicalName = `g${groupIndex}_b${entry.binding}`;
          if (entry.buffer) {
            let blockIndex = ctx.getUniformBlockIndex(program, canonicalName);
            if (blockIndex === ctx.INVALID_INDEX && nextUboSlot === 0) {
              if (ctx.getProgramParameter(program, ctx.ACTIVE_UNIFORM_BLOCKS) === 1) {
                blockIndex = 0;
              }
            }
            if (blockIndex !== ctx.INVALID_INDEX) {
              const slot = nextUboSlot++;
              uboBindings.set(key, slot);
              ctx.uniformBlockBinding(program, blockIndex, slot);
            } else {
              const loc = ctx.getUniformLocation(program, canonicalName);
              if (loc !== null) {
                const unit = nextTexUnit++;
                storageTexBindings.set(key, unit);
                ctx.uniform1i(loc, unit);
              }
            }
          } else if (entry.texture) {
            const unit = nextTexUnit++;
            textureBindings.set(key, unit);
            const loc = ctx.getUniformLocation(program, canonicalName);
            if (loc !== null) {
              ctx.uniform1i(loc, unit);
            }
          }
        }
      }
      ctx.useProgram(null);

      const vao = ctx.createVertexArray();
      const vertexBuffers = (desc.vertex?.buffers ?? []).map((vb) => ({
        arrayStride: vb.arrayStride,
        stepMode: vb.stepMode ?? "vertex",
        attributes: (vb.attributes ?? []).map((attr) => {
          const info = vertexFormatInfo(ctx, attr.format);
          return {
            shaderLocation: attr.shaderLocation,
            offset: attr.offset,
            components: info.components,
            type: info.type,
            isInteger: info.isInteger,
          };
        }),
      }));

      const target = desc.fragment?.targets?.[0];
      const blendDesc = target?.blend;
      const blend = blendDesc
        ? {
            colorSrc: glBlendFactor(ctx, blendDesc.color?.srcFactor),
            colorDst: glBlendFactor(ctx, blendDesc.color?.dstFactor),
            colorOp: glBlendOp(ctx, blendDesc.color?.operation),
            alphaSrc: glBlendFactor(ctx, blendDesc.alpha?.srcFactor),
            alphaDst: glBlendFactor(ctx, blendDesc.alpha?.dstFactor),
            alphaOp: glBlendOp(ctx, blendDesc.alpha?.operation),
          }
        : null;

      const depthStencil = desc.depthStencil
        ? {
            writeEnabled: Boolean(desc.depthStencil.depthWriteEnabled),
            compare: glCompareFunc(ctx, desc.depthStencil.depthCompare),
          }
        : null;

      return {
        label,
        program,
        vao,
        vertexBuffers,
        bindGroupLayouts,
        uboBindings,
        storageTexBindings,
        textureBindings,
        blend,
        depthStencil,
        cullMode: desc.primitive?.cullMode ?? "none",
        frontFace: desc.primitive?.frontFace ?? "ccw",
      };
    },

    createBindGroup(desc) {
      return {
        label: desc?.label ?? "",
        layout: desc?.layout,
        entries: desc?.entries ?? [],
      };
    },

    createCommandEncoder() {
      return {
        beginRenderPass(passDesc) {
          return new WebGL2RenderPass(backend, passDesc);
        },
        finish() {
          return {};
        },
      };
    },
  };

  const adapter = {
    isFallbackAdapter: false,
    backend: "webgl2",
    async requestDevice() {
      return device;
    },
  };

  return {
    backend: "webgl2",
    adapter,
    device,
    queue,
    preferredFormat: "rgba8unorm",
    getCanvasContext(canvas) {
      return backend.getCanvasContext(canvas);
    },
  };
}
