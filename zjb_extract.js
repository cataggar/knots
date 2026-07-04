const Zjb = class {
  new_handle(value) {
    if (value === null) {
      return 0;
    }
    const result = this._next_handle;
    this._handles.set(result, value);
    this._next_handle++;
    return result;
  }
  dataView() {
    if (this._cached_data_view.buffer.byteLength !== this.instance.exports.memory.buffer.byteLength) {
      this._cached_data_view = new DataView(this.instance.exports.memory.buffer);
    }
    return this._cached_data_view;
  }
  constructor() {
    this._decoder = new TextDecoder();
    this.imports = {
      "call__f64_now": (id) => {
        return this._handles.get(id).now();
      },
      "call__o_createCommandEncoder": (id) => {
        return this.new_handle(this._handles.get(id).createCommandEncoder());
      },
      "call__o_createView": (id) => {
        return this.new_handle(this._handles.get(id).createView());
      },
      "call__o_finish": (id) => {
        return this.new_handle(this._handles.get(id).finish());
      },
      "call__o_getBoundingClientRect": (id) => {
        return this.new_handle(this._handles.get(id).getBoundingClientRect());
      },
      "call__o_getCurrentTexture": (id) => {
        return this.new_handle(this._handles.get(id).getCurrentTexture());
      },
      "call__o_getPreferredCanvasFormat": (id) => {
        return this.new_handle(this._handles.get(id).getPreferredCanvasFormat());
      },
      "call__o_requestAdapter": (id) => {
        return this.new_handle(this._handles.get(id).requestAdapter());
      },
      "call__o_requestDevice": (id) => {
        return this.new_handle(this._handles.get(id).requestDevice());
      },
      "call__v_destroy": (id) => {
        this._handles.get(id).destroy();
      },
      "call__v_disconnect": (id) => {
        this._handles.get(id).disconnect();
      },
      "call__v_end": (id) => {
        this._handles.get(id).end();
      },
      "call__v_focus": (id) => {
        this._handles.get(id).focus();
      },
      "call__v_preventDefault": (id) => {
        this._handles.get(id).preventDefault();
      },
      "call__v_remove": (id) => {
        this._handles.get(id).remove();
      },
      "call__v_select": (id) => {
        this._handles.get(id).select();
      },
      "call_i32i32i32i32_v_setScissorRect": (arg0, arg1, arg2, arg3, id) => {
        this._handles.get(id).setScissorRect(arg0, arg1, arg2, arg3);
      },
      "call_i32i32i32i32i32_v_drawIndexed": (arg0, arg1, arg2, arg3, arg4, id) => {
        this._handles.get(id).drawIndexed(arg0, arg1, arg2, arg3, arg4);
      },
      "call_i32o_v_setBindGroup": (arg0, arg1, id) => {
        this._handles.get(id).setBindGroup(arg0, this._handles.get(arg1));
      },
      "call_i32of64f64_v_setVertexBuffer": (arg0, arg1, arg2, arg3, id) => {
        this._handles.get(id).setVertexBuffer(arg0, this._handles.get(arg1), arg2, arg3);
      },
      "call_o_o_beginRenderPass": (arg0, id) => {
        return this.new_handle(this._handles.get(id).beginRenderPass(this._handles.get(arg0)));
      },
      "call_o_o_createBindGroup": (arg0, id) => {
        return this.new_handle(this._handles.get(id).createBindGroup(this._handles.get(arg0)));
      },
      "call_o_o_createBindGroupLayout": (arg0, id) => {
        return this.new_handle(this._handles.get(id).createBindGroupLayout(this._handles.get(arg0)));
      },
      "call_o_o_createBuffer": (arg0, id) => {
        return this.new_handle(this._handles.get(id).createBuffer(this._handles.get(arg0)));
      },
      "call_o_o_createElement": (arg0, id) => {
        return this.new_handle(this._handles.get(id).createElement(this._handles.get(arg0)));
      },
      "call_o_o_createPipelineLayout": (arg0, id) => {
        return this.new_handle(this._handles.get(id).createPipelineLayout(this._handles.get(arg0)));
      },
      "call_o_o_createRenderPipeline": (arg0, id) => {
        return this.new_handle(this._handles.get(id).createRenderPipeline(this._handles.get(arg0)));
      },
      "call_o_o_createSampler": (arg0, id) => {
        return this.new_handle(this._handles.get(id).createSampler(this._handles.get(arg0)));
      },
      "call_o_o_createShaderModule": (arg0, id) => {
        return this.new_handle(this._handles.get(id).createShaderModule(this._handles.get(arg0)));
      },
      "call_o_o_createTexture": (arg0, id) => {
        return this.new_handle(this._handles.get(id).createTexture(this._handles.get(arg0)));
      },
      "call_o_o_getContext": (arg0, id) => {
        return this.new_handle(this._handles.get(id).getContext(this._handles.get(arg0)));
      },
      "call_o_o_getData": (arg0, id) => {
        return this.new_handle(this._handles.get(id).getData(this._handles.get(arg0)));
      },
      "call_o_o_querySelector": (arg0, id) => {
        return this.new_handle(this._handles.get(id).querySelector(this._handles.get(arg0)));
      },
      "call_o_o_writeText": (arg0, id) => {
        return this.new_handle(this._handles.get(id).writeText(this._handles.get(arg0)));
      },
      "call_o_v_appendChild": (arg0, id) => {
        this._handles.get(id).appendChild(this._handles.get(arg0));
      },
      "call_o_v_configure": (arg0, id) => {
        this._handles.get(id).configure(this._handles.get(arg0));
      },
      "call_o_v_info": (arg0, id) => {
        this._handles.get(id).info(this._handles.get(arg0));
      },
      "call_o_v_log": (arg0, id) => {
        this._handles.get(id).log(this._handles.get(arg0));
      },
      "call_o_v_observe": (arg0, id) => {
        this._handles.get(id).observe(this._handles.get(arg0));
      },
      "call_o_v_push": (arg0, id) => {
        this._handles.get(id).push(this._handles.get(arg0));
      },
      "call_o_v_requestAnimationFrame": (arg0, id) => {
        this._handles.get(id).requestAnimationFrame(this._handles.get(arg0));
      },
      "call_o_v_setPipeline": (arg0, id) => {
        this._handles.get(id).setPipeline(this._handles.get(arg0));
      },
      "call_o_v_submit": (arg0, id) => {
        this._handles.get(id).submit(this._handles.get(arg0));
      },
      "call_o_v_then": (arg0, id) => {
        this._handles.get(id).then(this._handles.get(arg0));
      },
      "call_oi32o_v_writeBuffer": (arg0, arg1, arg2, id) => {
        this._handles.get(id).writeBuffer(this._handles.get(arg0), arg1, this._handles.get(arg2));
      },
      "call_oo_o_encodeInto": (arg0, arg1, id) => {
        return this.new_handle(this._handles.get(id).encodeInto(this._handles.get(arg0), this._handles.get(arg1)));
      },
      "call_oo_v_addEventListener": (arg0, arg1, id) => {
        this._handles.get(id).addEventListener(this._handles.get(arg0), this._handles.get(arg1));
      },
      "call_oo_v_error": (arg0, arg1, id) => {
        this._handles.get(id).error(this._handles.get(arg0), this._handles.get(arg1));
      },
      "call_oo_v_setAttribute": (arg0, arg1, id) => {
        this._handles.get(id).setAttribute(this._handles.get(arg0), this._handles.get(arg1));
      },
      "call_oof64f64_v_setIndexBuffer": (arg0, arg1, arg2, arg3, id) => {
        this._handles.get(id).setIndexBuffer(this._handles.get(arg0), this._handles.get(arg1), arg2, arg3);
      },
      "call_oooo_v_writeTexture": (arg0, arg1, arg2, arg3, id) => {
        this._handles.get(id).writeTexture(this._handles.get(arg0), this._handles.get(arg1), this._handles.get(arg2), this._handles.get(arg3));
      },
      "get_b_ctrlKey": (id) => {
        return Boolean(this._handles.get(id).ctrlKey);
      },
      "get_b_metaKey": (id) => {
        return Boolean(this._handles.get(id).metaKey);
      },
      "get_b_repeat": (id) => {
        return Boolean(this._handles.get(id).repeat);
      },
      "get_b_shiftKey": (id) => {
        return Boolean(this._handles.get(id).shiftKey);
      },
      "get_f64_button": (id) => {
        return this._handles.get(id).button;
      },
      "get_f64_deltaMode": (id) => {
        return this._handles.get(id).deltaMode;
      },
      "get_f64_deltaX": (id) => {
        return this._handles.get(id).deltaX;
      },
      "get_f64_deltaY": (id) => {
        return this._handles.get(id).deltaY;
      },
      "get_f64_devicePixelRatio": (id) => {
        return this._handles.get(id).devicePixelRatio;
      },
      "get_f64_height": (id) => {
        return this._handles.get(id).height;
      },
      "get_f64_offsetX": (id) => {
        return this._handles.get(id).offsetX;
      },
      "get_f64_offsetY": (id) => {
        return this._handles.get(id).offsetY;
      },
      "get_f64_width": (id) => {
        return this._handles.get(id).width;
      },
      "get_f64_written": (id) => {
        return this._handles.get(id).written;
      },
      "get_o_Array": (id) => {
        return this.new_handle(this._handles.get(id).Array);
      },
      "get_o_Date": (id) => {
        return this.new_handle(this._handles.get(id).Date);
      },
      "get_o_Object": (id) => {
        return this.new_handle(this._handles.get(id).Object);
      },
      "get_o_ResizeObserver": (id) => {
        return this.new_handle(this._handles.get(id).ResizeObserver);
      },
      "get_o_TextEncoder": (id) => {
        return this.new_handle(this._handles.get(id).TextEncoder);
      },
      "get_o_body": (id) => {
        return this.new_handle(this._handles.get(id).body);
      },
      "get_o_clipboard": (id) => {
        return this.new_handle(this._handles.get(id).clipboard);
      },
      "get_o_clipboardData": (id) => {
        return this.new_handle(this._handles.get(id).clipboardData);
      },
      "get_o_code": (id) => {
        return this.new_handle(this._handles.get(id).code);
      },
      "get_o_console": (id) => {
        return this.new_handle(this._handles.get(id).console);
      },
      "get_o_document": (id) => {
        return this.new_handle(this._handles.get(id).document);
      },
      "get_o_gpu": (id) => {
        return this.new_handle(this._handles.get(id).gpu);
      },
      "get_o_key": (id) => {
        return this.new_handle(this._handles.get(id).key);
      },
      "get_o_knots_wasm_onBlur": (id) => {
        return this.new_handle(this._handles.get(id).knots_wasm_onBlur);
      },
      "get_o_knots_wasm_onCanvasResize": (id) => {
        return this.new_handle(this._handles.get(id).knots_wasm_onCanvasResize);
      },
      "get_o_knots_wasm_onContextMenu": (id) => {
        return this.new_handle(this._handles.get(id).knots_wasm_onContextMenu);
      },
      "get_o_knots_wasm_onKeyDown": (id) => {
        return this.new_handle(this._handles.get(id).knots_wasm_onKeyDown);
      },
      "get_o_knots_wasm_onKeyUp": (id) => {
        return this.new_handle(this._handles.get(id).knots_wasm_onKeyUp);
      },
      "get_o_knots_wasm_onMouseDown": (id) => {
        return this.new_handle(this._handles.get(id).knots_wasm_onMouseDown);
      },
      "get_o_knots_wasm_onMouseMove": (id) => {
        return this.new_handle(this._handles.get(id).knots_wasm_onMouseMove);
      },
      "get_o_knots_wasm_onMouseUp": (id) => {
        return this.new_handle(this._handles.get(id).knots_wasm_onMouseUp);
      },
      "get_o_knots_wasm_onPaste": (id) => {
        return this.new_handle(this._handles.get(id).knots_wasm_onPaste);
      },
      "get_o_knots_wasm_onWheel": (id) => {
        return this.new_handle(this._handles.get(id).knots_wasm_onWheel);
      },
      "get_o_knots_wasm_rafTick": (id) => {
        return this.new_handle(this._handles.get(id).knots_wasm_rafTick);
      },
      "get_o_knots_webgpu_js_onAdapterReady": (id) => {
        return this.new_handle(this._handles.get(id).knots_webgpu_js_onAdapterReady);
      },
      "get_o_knots_webgpu_js_onDeviceReady": (id) => {
        return this.new_handle(this._handles.get(id).knots_webgpu_js_onDeviceReady);
      },
      "get_o_navigator": (id) => {
        return this.new_handle(this._handles.get(id).navigator);
      },
      "get_o_performance": (id) => {
        return this.new_handle(this._handles.get(id).performance);
      },
      "get_o_queue": (id) => {
        return this.new_handle(this._handles.get(id).queue);
      },
      "get_o_style": (id) => {
        return this.new_handle(this._handles.get(id).style);
      },
      "get_o_window": (id) => {
        return this.new_handle(this._handles.get(id).window);
      },
      "new__o": (id) => {
        return this.new_handle(new (this._handles.get(id))());
      },
      "new_o_o": (arg0, id) => {
        return this.new_handle(new (this._handles.get(id))(this._handles.get(arg0)));
      },
      "release": (id) => {
        this._handles.delete(id);
      },
      "set_f64_a": (arg0, id) => {
        this._handles.get(id).a = arg0;
      },
      "set_f64_arrayStride": (arg0, id) => {
        this._handles.get(id).arrayStride = arg0;
      },
      "set_f64_b": (arg0, id) => {
        this._handles.get(id).b = arg0;
      },
      "set_f64_g": (arg0, id) => {
        this._handles.get(id).g = arg0;
      },
      "set_f64_offset": (arg0, id) => {
        this._handles.get(id).offset = arg0;
      },
      "set_f64_r": (arg0, id) => {
        this._handles.get(id).r = arg0;
      },
      "set_f64_size": (arg0, id) => {
        this._handles.get(id).size = arg0;
      },
      "set_i32_binding": (arg0, id) => {
        this._handles.get(id).binding = arg0;
      },
      "set_i32_bytesPerRow": (arg0, id) => {
        this._handles.get(id).bytesPerRow = arg0;
      },
      "set_i32_depthOrArrayLayers": (arg0, id) => {
        this._handles.get(id).depthOrArrayLayers = arg0;
      },
      "set_i32_height": (arg0, id) => {
        this._handles.get(id).height = arg0;
      },
      "set_i32_rowsPerImage": (arg0, id) => {
        this._handles.get(id).rowsPerImage = arg0;
      },
      "set_i32_shaderLocation": (arg0, id) => {
        this._handles.get(id).shaderLocation = arg0;
      },
      "set_i32_usage": (arg0, id) => {
        this._handles.get(id).usage = arg0;
      },
      "set_i32_visibility": (arg0, id) => {
        this._handles.get(id).visibility = arg0;
      },
      "set_i32_width": (arg0, id) => {
        this._handles.get(id).width = arg0;
      },
      "set_i32_x": (arg0, id) => {
        this._handles.get(id).x = arg0;
      },
      "set_i32_y": (arg0, id) => {
        this._handles.get(id).y = arg0;
      },
      "set_i32_z": (arg0, id) => {
        this._handles.get(id).z = arg0;
      },
      "set_o_addressModeU": (arg0, id) => {
        this._handles.get(id).addressModeU = this._handles.get(arg0);
      },
      "set_o_addressModeV": (arg0, id) => {
        this._handles.get(id).addressModeV = this._handles.get(arg0);
      },
      "set_o_alpha": (arg0, id) => {
        this._handles.get(id).alpha = this._handles.get(arg0);
      },
      "set_o_alphaMode": (arg0, id) => {
        this._handles.get(id).alphaMode = this._handles.get(arg0);
      },
      "set_o_attributes": (arg0, id) => {
        this._handles.get(id).attributes = this._handles.get(arg0);
      },
      "set_o_bindGroupLayouts": (arg0, id) => {
        this._handles.get(id).bindGroupLayouts = this._handles.get(arg0);
      },
      "set_o_blend": (arg0, id) => {
        this._handles.get(id).blend = this._handles.get(arg0);
      },
      "set_o_buffer": (arg0, id) => {
        this._handles.get(id).buffer = this._handles.get(arg0);
      },
      "set_o_buffers": (arg0, id) => {
        this._handles.get(id).buffers = this._handles.get(arg0);
      },
      "set_o_clearValue": (arg0, id) => {
        this._handles.get(id).clearValue = this._handles.get(arg0);
      },
      "set_o_code": (arg0, id) => {
        this._handles.get(id).code = this._handles.get(arg0);
      },
      "set_o_color": (arg0, id) => {
        this._handles.get(id).color = this._handles.get(arg0);
      },
      "set_o_colorAttachments": (arg0, id) => {
        this._handles.get(id).colorAttachments = this._handles.get(arg0);
      },
      "set_o_device": (arg0, id) => {
        this._handles.get(id).device = this._handles.get(arg0);
      },
      "set_o_dstFactor": (arg0, id) => {
        this._handles.get(id).dstFactor = this._handles.get(arg0);
      },
      "set_o_entries": (arg0, id) => {
        this._handles.get(id).entries = this._handles.get(arg0);
      },
      "set_o_entryPoint": (arg0, id) => {
        this._handles.get(id).entryPoint = this._handles.get(arg0);
      },
      "set_o_format": (arg0, id) => {
        this._handles.get(id).format = this._handles.get(arg0);
      },
      "set_o_fragment": (arg0, id) => {
        this._handles.get(id).fragment = this._handles.get(arg0);
      },
      "set_o_height": (arg0, id) => {
        this._handles.get(id).height = this._handles.get(arg0);
      },
      "set_o_label": (arg0, id) => {
        this._handles.get(id).label = this._handles.get(arg0);
      },
      "set_o_layout": (arg0, id) => {
        this._handles.get(id).layout = this._handles.get(arg0);
      },
      "set_o_left": (arg0, id) => {
        this._handles.get(id).left = this._handles.get(arg0);
      },
      "set_o_loadOp": (arg0, id) => {
        this._handles.get(id).loadOp = this._handles.get(arg0);
      },
      "set_o_magFilter": (arg0, id) => {
        this._handles.get(id).magFilter = this._handles.get(arg0);
      },
      "set_o_minFilter": (arg0, id) => {
        this._handles.get(id).minFilter = this._handles.get(arg0);
      },
      "set_o_module": (arg0, id) => {
        this._handles.get(id).module = this._handles.get(arg0);
      },
      "set_o_opacity": (arg0, id) => {
        this._handles.get(id).opacity = this._handles.get(arg0);
      },
      "set_o_operation": (arg0, id) => {
        this._handles.get(id).operation = this._handles.get(arg0);
      },
      "set_o_origin": (arg0, id) => {
        this._handles.get(id).origin = this._handles.get(arg0);
      },
      "set_o_position": (arg0, id) => {
        this._handles.get(id).position = this._handles.get(arg0);
      },
      "set_o_resource": (arg0, id) => {
        this._handles.get(id).resource = this._handles.get(arg0);
      },
      "set_o_sampleType": (arg0, id) => {
        this._handles.get(id).sampleType = this._handles.get(arg0);
      },
      "set_o_sampler": (arg0, id) => {
        this._handles.get(id).sampler = this._handles.get(arg0);
      },
      "set_o_size": (arg0, id) => {
        this._handles.get(id).size = this._handles.get(arg0);
      },
      "set_o_srcFactor": (arg0, id) => {
        this._handles.get(id).srcFactor = this._handles.get(arg0);
      },
      "set_o_stepMode": (arg0, id) => {
        this._handles.get(id).stepMode = this._handles.get(arg0);
      },
      "set_o_storeOp": (arg0, id) => {
        this._handles.get(id).storeOp = this._handles.get(arg0);
      },
      "set_o_targets": (arg0, id) => {
        this._handles.get(id).targets = this._handles.get(arg0);
      },
      "set_o_texture": (arg0, id) => {
        this._handles.get(id).texture = this._handles.get(arg0);
      },
      "set_o_top": (arg0, id) => {
        this._handles.get(id).top = this._handles.get(arg0);
      },
      "set_o_type": (arg0, id) => {
        this._handles.get(id).type = this._handles.get(arg0);
      },
      "set_o_vertex": (arg0, id) => {
        this._handles.get(id).vertex = this._handles.get(arg0);
      },
      "set_o_view": (arg0, id) => {
        this._handles.get(id).view = this._handles.get(arg0);
      },
      "set_o_viewDimension": (arg0, id) => {
        this._handles.get(id).viewDimension = this._handles.get(arg0);
      },
      "set_o_width": (arg0, id) => {
        this._handles.get(id).width = this._handles.get(arg0);
      },
      "string": (ptr, len) => {
        return this.new_handle(this._decoder.decode(new Uint8Array(this.instance.exports.memory.buffer, ptr, len)));
      },
      "throwAndRelease": (id) => {
        var message = this._handles.get(id);
        this._handles.delete(id);
        throw message;
      },
      "u8ArrayView": (ptr, len) => {
        return this.new_handle(new Uint8Array(this.instance.exports.memory.buffer, ptr, len));
      },
    };
    this.exports = {
      "knots_wasm_rafTick": (arg0) => {
        this.instance.exports.zjb_fn_f64_v_knots_wasm_rafTick(arg0);
      },
      "knots_wasm_onBlur": (arg0) => {
        this.instance.exports.zjb_fn_o_v_knots_wasm_onBlur(this.new_handle(arg0));
      },
      "knots_wasm_onCanvasResize": (arg0) => {
        this.instance.exports.zjb_fn_o_v_knots_wasm_onCanvasResize(this.new_handle(arg0));
      },
      "knots_wasm_onContextMenu": (arg0) => {
        this.instance.exports.zjb_fn_o_v_knots_wasm_onContextMenu(this.new_handle(arg0));
      },
      "knots_wasm_onKeyDown": (arg0) => {
        this.instance.exports.zjb_fn_o_v_knots_wasm_onKeyDown(this.new_handle(arg0));
      },
      "knots_wasm_onKeyUp": (arg0) => {
        this.instance.exports.zjb_fn_o_v_knots_wasm_onKeyUp(this.new_handle(arg0));
      },
      "knots_wasm_onMouseDown": (arg0) => {
        this.instance.exports.zjb_fn_o_v_knots_wasm_onMouseDown(this.new_handle(arg0));
      },
      "knots_wasm_onMouseMove": (arg0) => {
        this.instance.exports.zjb_fn_o_v_knots_wasm_onMouseMove(this.new_handle(arg0));
      },
      "knots_wasm_onMouseUp": (arg0) => {
        this.instance.exports.zjb_fn_o_v_knots_wasm_onMouseUp(this.new_handle(arg0));
      },
      "knots_wasm_onPaste": (arg0) => {
        this.instance.exports.zjb_fn_o_v_knots_wasm_onPaste(this.new_handle(arg0));
      },
      "knots_wasm_onWheel": (arg0) => {
        this.instance.exports.zjb_fn_o_v_knots_wasm_onWheel(this.new_handle(arg0));
      },
      "knots_webgpu_js_onAdapterReady": (arg0) => {
        this.instance.exports.zjb_fn_o_v_knots_webgpu_js_onAdapterReady(this.new_handle(arg0));
      },
      "knots_webgpu_js_onDeviceReady": (arg0) => {
        this.instance.exports.zjb_fn_o_v_knots_webgpu_js_onDeviceReady(this.new_handle(arg0));
      },
    };
    this.instance = null;
    this._cached_data_view = null;
    this._export_reverse_handles = {};
    this._handles = new Map();
    this._handles.set(0, null);
    this._handles.set(1, window);
    this._handles.set(2, "");
    this._handles.set(3, this.exports);
    this._next_handle = 4;
  }
  setInstance(instance) {
    this.instance = instance;
    const initialView = new DataView(instance.exports.memory.buffer);
    this._cached_data_view = initialView;
  }
};
