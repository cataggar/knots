const textDecoder = new TextDecoder("utf-8");
const textEncoder = new TextEncoder();

const WASM_MAGIC = [0x00, 0x61, 0x73, 0x6d];
const COMPONENT_PREAMBLE = [0x0d, 0x00, 0x01, 0x00];
const SOURCE_INTERFACE_PREFIX = "knots:visual/source";
const UPSTREAM_INTERFACE_PREFIX = "knots:visual/upstream";
const SHAPE_BYTE_STRIDE = 48;

class BinaryReader {
  constructor(bytes, pos = 0, end = bytes.byteLength) {
    this.bytes = bytes;
    this.pos = pos;
    this.end = end;
  }

  remaining() {
    return this.end - this.pos;
  }

  readByte() {
    if (this.pos >= this.end) throw new Error("Unexpected EOF in component binary");
    return this.bytes[this.pos++];
  }

  readBytes(len) {
    if (len > this.remaining()) throw new Error("Unexpected EOF reading component slice");
    const slice = this.bytes.subarray(this.pos, this.pos + len);
    this.pos += len;
    return slice;
  }

  readU32Leb() {
    let result = 0;
    let shift = 0;
    for (let i = 0; i < 5; i++) {
      const byte = this.readByte();
      result |= (byte & 0x7f) << shift;
      if ((byte & 0x80) === 0) return result >>> 0;
      shift += 7;
    }
    throw new Error("LEB128 u32 overflow");
  }

  readS33Leb() {
    let result = 0;
    let shift = 0;
    let byte = 0;
    for (let i = 0; i < 5; i++) {
      byte = this.readByte();
      result |= (byte & 0x7f) << shift;
      shift += 7;
      if ((byte & 0x80) === 0) break;
    }
    if (shift < 32 && (byte & 0x40) !== 0) {
      result |= ~0 << shift;
    }
    return result;
  }

  readName() {
    const len = this.readU32Leb();
    return textDecoder.decode(this.readBytes(len));
  }

  readExternName() {
    const disc = this.readByte();
    if (disc === 0x00 || disc === 0x01) {
      return this.readName();
    }
    if (disc === 0x02) {
      const base = this.readName();
      const attrCount = this.readU32Leb();
      let versionSuffix = "";
      for (let i = 0; i < attrCount; i++) {
        const attrKind = this.readByte();
        const attrVal = this.readName();
        if (attrKind === 0x01) versionSuffix = attrVal;
      }
      return base + versionSuffix;
    }
    throw new Error(`Unsupported externname discriminant: 0x${disc.toString(16)}`);
  }
}

function parseValType(reader, typeSpace) {
  const b = reader.bytes[reader.pos];
  // Negative 7-bit SLEB128 opcodes (0x64..0x7f) represent primitive WIT value types.
  if (b >= 0x64 && b <= 0x7f) {
    reader.pos += 1;
    switch (b) {
      case 0x7f:
        return { kind: "bool" };
      case 0x7e:
        return { kind: "s8" };
      case 0x7d:
        return { kind: "u8" };
      case 0x7c:
        return { kind: "s16" };
      case 0x7b:
        return { kind: "u16" };
      case 0x7a:
        return { kind: "s32" };
      case 0x79:
        return { kind: "u32" };
      case 0x78:
        return { kind: "s64" };
      case 0x77:
        return { kind: "u64" };
      case 0x76:
        return { kind: "f32" };
      case 0x75:
        return { kind: "f64" };
      case 0x74:
        return { kind: "char" };
      case 0x73:
        return { kind: "string" };
      default:
        return { kind: "prim", opcode: b };
    }
  }
  const idx = reader.readS33Leb();
  if (idx < 0 || idx >= typeSpace.length) {
    throw new Error(`Invalid component valtype index ${idx} (space=${typeSpace.length})`);
  }
  return typeSpace[idx];
}

function parseDefType(reader, typeSpace, outerScopes) {
  const op = reader.bytes[reader.pos];
  if (op === 0x72) {
    // record
    reader.pos += 1;
    const count = reader.readU32Leb();
    const fields = [];
    for (let i = 0; i < count; i++) {
      const name = reader.readName();
      const type = parseValType(reader, typeSpace);
      fields.push({ name, type });
    }
    return { kind: "record", fields };
  }
  if (op === 0x71) {
    // variant
    reader.pos += 1;
    const count = reader.readU32Leb();
    const cases = [];
    for (let i = 0; i < count; i++) {
      const name = reader.readName();
      const hasType = reader.readByte();
      const type = hasType ? parseValType(reader, typeSpace) : null;
      const hasRefines = reader.readByte();
      if (hasRefines) reader.readU32Leb();
      cases.push({ name, type });
    }
    return { kind: "variant", cases };
  }
  if (op === 0x70) {
    // list
    reader.pos += 1;
    const elem = parseValType(reader, typeSpace);
    return { kind: "list", elem };
  }
  if (op === 0x6f) {
    // tuple
    reader.pos += 1;
    const count = reader.readU32Leb();
    const types = [];
    for (let i = 0; i < count; i++) types.push(parseValType(reader, typeSpace));
    return { kind: "tuple", types };
  }
  if (op === 0x6e) {
    // flags
    reader.pos += 1;
    const count = reader.readU32Leb();
    const names = [];
    for (let i = 0; i < count; i++) names.push(reader.readName());
    return { kind: "flags", names };
  }
  if (op === 0x6d) {
    // enum
    reader.pos += 1;
    const count = reader.readU32Leb();
    const cases = [];
    for (let i = 0; i < count; i++) cases.push(reader.readName());
    return { kind: "enum", cases };
  }
  if (op === 0x6b) {
    // option
    reader.pos += 1;
    return { kind: "option", elem: parseValType(reader, typeSpace) };
  }
  if (op === 0x6a) {
    // result
    reader.pos += 1;
    const ok = reader.readByte() ? parseValType(reader, typeSpace) : null;
    const err = reader.readByte() ? parseValType(reader, typeSpace) : null;
    return { kind: "result", ok, err };
  }
  if (op === 0x69 || op === 0x68) {
    // own / borrow handle
    reader.pos += 1;
    return { kind: op === 0x69 ? "own" : "borrow", idx: reader.readU32Leb() };
  }
  if (op === 0x40 || op === 0x43) {
    // func / async func
    reader.pos += 1;
    const paramCount = reader.readU32Leb();
    const params = [];
    for (let i = 0; i < paramCount; i++) {
      const name = reader.readName();
      const type = parseValType(reader, typeSpace);
      params.push({ name, type });
    }
    const resultTag = reader.readByte();
    let result = null;
    if (resultTag === 0x00) {
      result = parseValType(reader, typeSpace);
    } else if (resultTag === 0x01) {
      const namedCount = reader.readU32Leb();
      if (namedCount !== 0) throw new Error("Deprecated named multi-results unsupported");
    } else {
      throw new Error(`Invalid functype result tag: 0x${resultTag.toString(16)}`);
    }
    return { kind: "func", isAsync: op === 0x43, params, result };
  }
  if (op === 0x42) {
    // instancetype
    reader.pos += 1;
    const declCount = reader.readU32Leb();
    const localTypes = [];
    const localInstances = [];
    const exportedTypes = Object.create(null);
    const exportedFuncs = Object.create(null);
    const nextScopes = [{ types: localTypes, instances: localInstances }, ...outerScopes];

    for (let i = 0; i < declCount; i++) {
      const declTag = reader.readByte();
      if (declTag === 0x01) {
        localTypes.push(parseDefType(reader, localTypes, nextScopes));
      } else if (declTag === 0x02) {
        // alias inside instancetype
        const sort = readSort(reader);
        const target = reader.readByte();
        if (target === 0x02) {
          const count = reader.readU32Leb();
          const idx = reader.readU32Leb();
          const scope = nextScopes[count];
          if (sort.kind === "type") localTypes.push(scope.types[idx]);
          else if (sort.kind === "instance") localInstances.push(scope.instances[idx]);
        } else if (target === 0x00) {
          const instIdx = reader.readU32Leb();
          const name = reader.readName();
          const inst = localInstances[instIdx];
          if (sort.kind === "type") localTypes.push(inst?.exportedTypes?.[name] ?? { kind: "opaque" });
        } else {
          throw new Error(`Unsupported alias target 0x${target.toString(16)} in instancetype`);
        }
      } else if (declTag === 0x04) {
        // exportdecl inside instancetype
        const name = reader.readExternName();
        const desc = readExternDesc(reader, localTypes);
        if (desc.kind === "type") {
          const resolved = desc.bound === "eq" ? localTypes[desc.idx] : { kind: "resource", name };
          localTypes.push(resolved);
          exportedTypes[name] = resolved;
        } else if (desc.kind === "func") {
          exportedFuncs[name] = localTypes[desc.idx];
        } else if (desc.kind === "instance") {
          localInstances.push(localTypes[desc.idx]);
        }
      } else {
        throw new Error(`Unsupported instancetype decl tag: 0x${declTag.toString(16)}`);
      }
    }
    return { kind: "instance", exportedTypes, exportedFuncs };
  }
  return parseValType(reader, typeSpace);
}

function readSort(reader) {
  const b = reader.readByte();
  if (b === 0x00) {
    const core = reader.readByte();
    const names = { 0x00: "func", 0x01: "table", 0x02: "memory", 0x03: "global", 0x11: "module", 0x12: "instance" };
    return { space: "core", kind: names[core] ?? `core_${core}` };
  }
  const names = { 0x01: "func", 0x02: "value", 0x03: "type", 0x04: "component", 0x05: "instance" };
  return { space: "component", kind: names[b] ?? `comp_${b}` };
}

function readExternDesc(reader, typeSpace) {
  const tag = reader.readByte();
  switch (tag) {
    case 0x00: {
      const sub = reader.readByte();
      if (sub !== 0x11) throw new Error(`Invalid core externdesc 0x${sub.toString(16)}`);
      return { kind: "core_module", idx: reader.readU32Leb() };
    }
    case 0x01:
      return { kind: "func", idx: reader.readU32Leb() };
    case 0x02: {
      const disc = reader.readByte();
      if (disc === 0x00) return { kind: "value", idx: reader.readU32Leb() };
      return { kind: "value", valType: parseValType(reader, typeSpace) };
    }
    case 0x03: {
      const bound = reader.readByte();
      if (bound === 0x00) return { kind: "type", bound: "eq", idx: reader.readU32Leb() };
      if (bound === 0x01) return { kind: "type", bound: "sub_resource" };
      throw new Error(`Invalid typebound 0x${bound.toString(16)}`);
    }
    case 0x04:
      return { kind: "component", idx: reader.readU32Leb() };
    case 0x05:
      return { kind: "instance", idx: reader.readU32Leb() };
    default:
      throw new Error(`Invalid externdesc 0x${tag.toString(16)}`);
  }
}

function readCanonOpts(reader) {
  const count = reader.readU32Leb();
  const opts = { stringEncoding: "utf8", memory: null, realloc: null, postReturn: null };
  for (let i = 0; i < count; i++) {
    const tag = reader.readByte();
    if (tag === 0x00) opts.stringEncoding = "utf8";
    else if (tag === 0x01) opts.stringEncoding = "utf16";
    else if (tag === 0x02) opts.stringEncoding = "latin1+utf16";
    else if (tag === 0x03) opts.memory = reader.readU32Leb();
    else if (tag === 0x04) opts.realloc = reader.readU32Leb();
    else if (tag === 0x05) opts.postReturn = reader.readU32Leb();
    else if (tag === 0x06) opts.async = true;
    else if (tag === 0x07) opts.callback = reader.readU32Leb();
    else throw new Error(`Unsupported canonopt 0x${tag.toString(16)}`);
  }
  return opts;
}

// ── Canonical ABI layout & lift/lower helpers (knots:visual@0.1.0 fast + generic) ──

function alignTo(offset, align) {
  return (offset + align - 1) & ~(align - 1);
}

function typeLayout(type) {
  if (type._layout) return type._layout;
  let layout;
  switch (type.kind) {
    case "bool":
    case "u8":
    case "s8":
      layout = { size: 1, align: 1, flat: ["i32"] };
      break;
    case "enum":
      layout =
        type.cases.length <= 256
          ? { size: 1, align: 1, flat: ["i32"] }
          : { size: 2, align: 2, flat: ["i32"] };
      break;
    case "u16":
    case "s16":
      layout = { size: 2, align: 2, flat: ["i32"] };
      break;
    case "u32":
    case "s32":
    case "char":
      layout = { size: 4, align: 4, flat: ["i32"] };
      break;
    case "u64":
    case "s64":
      layout = { size: 8, align: 8, flat: ["i64"] };
      break;
    case "f32":
      layout = { size: 4, align: 4, flat: ["f32"] };
      break;
    case "f64":
      layout = { size: 8, align: 8, flat: ["f64"] };
      break;
    case "string":
    case "list":
      layout = { size: 8, align: 4, flat: ["i32", "i32"] };
      break;
    case "record": {
      let size = 0;
      let maxAlign = 1;
      const flat = [];
      const fieldOffsets = [];
      for (const f of type.fields) {
        const fl = typeLayout(f.type);
        size = alignTo(size, fl.align);
        fieldOffsets.push(size);
        size += fl.size;
        if (fl.align > maxAlign) maxAlign = fl.align;
        flat.push(...fl.flat);
      }
      size = alignTo(size, maxAlign);
      layout = { size, align: maxAlign, flat, fieldOffsets };
      break;
    }
    default:
      throw new Error(`Unsupported Canonical ABI type kind: ${type.kind}`);
  }
  type._layout = layout;
  return layout;
}

function loadFromMemory(type, view, bytes, ptr) {
  switch (type.kind) {
    case "bool":
      return bytes[ptr] !== 0;
    case "u8":
    case "enum":
      return bytes[ptr];
    case "s8":
      return view.getInt8(ptr);
    case "u16":
      return view.getUint16(ptr, true);
    case "s16":
      return view.getInt16(ptr, true);
    case "u32":
      return view.getUint32(ptr, true);
    case "s32":
      return view.getInt32(ptr, true);
    case "f32":
      return view.getFloat32(ptr, true);
    case "f64":
      return view.getFloat64(ptr, true);
    case "string": {
      const strPtr = view.getUint32(ptr, true);
      const strLen = view.getUint32(ptr + 4, true);
      if (strLen === 0) return "";
      return textDecoder.decode(bytes.subarray(strPtr, strPtr + strLen));
    }
    case "list": {
      const listPtr = view.getUint32(ptr, true);
      const listLen = view.getUint32(ptr + 4, true);
      if (type.elem.kind === "u8") {
        return bytes.slice(listPtr, listPtr + listLen);
      }
      if (type.elem.kind === "f32") {
        const out = new Float32Array(listLen);
        for (let i = 0; i < listLen; i++) out[i] = view.getFloat32(listPtr + i * 4, true);
        return out;
      }
      const elemLayout = typeLayout(type.elem);
      // Fast raw-bytes carrier for `list<draw-shape>` (stride 48) so composition & host rendering copy raw bytes!
      if (type.elem.kind === "record" && elemLayout.size === SHAPE_BYTE_STRIDE && type.elem.fields.length === 12) {
        return {
          __rawShapes: bytes.slice(listPtr, listPtr + listLen * SHAPE_BYTE_STRIDE),
          length: listLen,
        };
      }
      const arr = new Array(listLen);
      for (let i = 0; i < listLen; i++) {
        arr[i] = loadFromMemory(type.elem, view, bytes, listPtr + i * elemLayout.size);
      }
      return arr;
    }
    case "record": {
      const layout = typeLayout(type);
      const obj = Object.create(null);
      for (let i = 0; i < type.fields.length; i++) {
        const f = type.fields[i];
        obj[f.name] = loadFromMemory(f.type, view, bytes, ptr + layout.fieldOffsets[i]);
      }
      return obj;
    }
    default:
      throw new Error(`Unsupported loadFromMemory type: ${type.kind}`);
  }
}

function storeToMemory(type, val, memory, realloc, ptr) {
  const storeListAndRefresh = (elemType, items) => {
    if (elemType.kind === "u8") {
      const u8 = items instanceof Uint8Array ? items : new Uint8Array(items);
      if (u8.byteLength === 0) return { listPtr: 0, listLen: 0 };
      const listPtr = realloc(0, 0, 1, u8.byteLength) >>> 0;
      new Uint8Array(memory.buffer).set(u8, listPtr);
      return { listPtr, listLen: u8.byteLength };
    }
    if (items && items.__rawShapes instanceof Uint8Array) {
      const raw = items.__rawShapes;
      const count = items.length >>> 0;
      if (count === 0) return { listPtr: 0, listLen: 0 };
      const listPtr = realloc(0, 0, 4, raw.byteLength) >>> 0;
      new Uint8Array(memory.buffer).set(raw, listPtr);
      return { listPtr, listLen: count };
    }
    const elemLayout = typeLayout(elemType);
    const count = items?.length ?? 0;
    if (count === 0) return { listPtr: 0, listLen: 0 };
    const listPtr = realloc(0, 0, elemLayout.align, count * elemLayout.size) >>> 0;
    for (let i = 0; i < count; i++) {
      storeToMemory(elemType, items[i], memory, realloc, listPtr + i * elemLayout.size);
    }
    return { listPtr, listLen: count };
  };

  switch (type.kind) {
    case "bool":
      new Uint8Array(memory.buffer)[ptr] = val ? 1 : 0;
      return;
    case "u8":
    case "enum":
      new Uint8Array(memory.buffer)[ptr] = Number(val) & 0xff;
      return;
    case "u32":
      new DataView(memory.buffer).setUint32(ptr, Number(val) >>> 0, true);
      return;
    case "s32":
      new DataView(memory.buffer).setInt32(ptr, Number(val) | 0, true);
      return;
    case "f32":
      new DataView(memory.buffer).setFloat32(ptr, Number(val), true);
      return;
    case "f64":
      new DataView(memory.buffer).setFloat64(ptr, Number(val), true);
      return;
    case "string": {
      const encoded = textEncoder.encode(String(val ?? ""));
      const strPtr = encoded.byteLength > 0 ? realloc(0, 0, 1, encoded.byteLength) >>> 0 : 0;
      if (encoded.byteLength > 0) new Uint8Array(memory.buffer).set(encoded, strPtr);
      const view = new DataView(memory.buffer);
      view.setUint32(ptr, strPtr, true);
      view.setUint32(ptr + 4, encoded.byteLength, true);
      return;
    }
    case "list": {
      const { listPtr, listLen } = storeListAndRefresh(type.elem, val);
      const view = new DataView(memory.buffer);
      view.setUint32(ptr, listPtr, true);
      view.setUint32(ptr + 4, listLen, true);
      return;
    }
    case "record": {
      const layout = typeLayout(type);
      for (let i = 0; i < type.fields.length; i++) {
        const f = type.fields[i];
        storeToMemory(f.type, val[f.name], memory, realloc, ptr + layout.fieldOffsets[i]);
      }
      return;
    }
    default:
      throw new Error(`Unsupported storeToMemory type: ${type.kind}`);
  }
}

function lowerFlatValue(type, val, memory, realloc, outArgs) {
  switch (type.kind) {
    case "bool":
      outArgs.push(val ? 1 : 0);
      return;
    case "u8":
    case "s8":
    case "u16":
    case "s16":
    case "u32":
    case "s32":
    case "enum":
      outArgs.push(Number(val) | 0);
      return;
    case "f32":
    case "f64":
      outArgs.push(Number(val));
      return;
    case "string": {
      const encoded = textEncoder.encode(String(val ?? ""));
      if (encoded.byteLength === 0) {
        outArgs.push(0, 0);
        return;
      }
      const ptr = realloc(0, 0, 1, encoded.byteLength) >>> 0;
      new Uint8Array(memory.buffer).set(encoded, ptr);
      outArgs.push(ptr | 0, encoded.byteLength | 0);
      return;
    }
    case "list": {
      if (type.elem.kind === "f32") {
        const f32 = val instanceof Float32Array ? val : Float32Array.from(val ?? []);
        if (f32.length === 0) {
          outArgs.push(0, 0);
          return;
        }
        const ptr = realloc(0, 0, 4, f32.byteLength) >>> 0;
        const view = new DataView(memory.buffer);
        for (let i = 0; i < f32.length; i++) view.setFloat32(ptr + i * 4, f32[i], true);
        outArgs.push(ptr | 0, f32.length | 0);
        return;
      }
      const elemLayout = typeLayout(type.elem);
      const count = val?.length ?? 0;
      if (count === 0) {
        outArgs.push(0, 0);
        return;
      }
      const ptr = realloc(0, 0, elemLayout.align, count * elemLayout.size) >>> 0;
      for (let i = 0; i < count; i++) {
        storeToMemory(type.elem, val[i], memory, realloc, ptr + i * elemLayout.size);
      }
      outArgs.push(ptr | 0, count | 0);
      return;
    }
    case "record":
      for (const f of type.fields) {
        lowerFlatValue(f.type, val[f.name], memory, realloc, outArgs);
      }
      return;
    default:
      throw new Error(`Unsupported lowerFlatValue type: ${type.kind}`);
  }
}

function liftFlatArgs(type, flatArgs, cursor, view, bytes) {
  switch (type.kind) {
    case "bool":
      return flatArgs[cursor.i++] !== 0;
    case "u8":
    case "enum":
      return flatArgs[cursor.i++] & 0xff;
    case "u32":
      return flatArgs[cursor.i++] >>> 0;
    case "s32":
      return flatArgs[cursor.i++] | 0;
    case "f32":
    case "f64":
      return Number(flatArgs[cursor.i++]);
    case "string": {
      const ptr = flatArgs[cursor.i++] >>> 0;
      const len = flatArgs[cursor.i++] >>> 0;
      return len === 0 ? "" : textDecoder.decode(bytes.subarray(ptr, ptr + len));
    }
    case "list": {
      const ptr = flatArgs[cursor.i++] >>> 0;
      const len = flatArgs[cursor.i++] >>> 0;
      if (type.elem.kind === "f32") {
        const out = new Float32Array(len);
        for (let i = 0; i < len; i++) out[i] = view.getFloat32(ptr + i * 4, true);
        return out;
      }
      const elemLayout = typeLayout(type.elem);
      const out = new Array(len);
      for (let i = 0; i < len; i++) {
        out[i] = loadFromMemory(type.elem, view, bytes, ptr + i * elemLayout.size);
      }
      return out;
    }
    case "record": {
      const obj = Object.create(null);
      for (const f of type.fields) {
        obj[f.name] = liftFlatArgs(f.type, flatArgs, cursor, view, bytes);
      }
      return obj;
    }
    default:
      throw new Error(`Unsupported liftFlatArgs type: ${type.kind}`);
  }
}

function createCanonLift(coreFunc, funcType, memory, realloc, postReturn) {
  let totalFlatParams = 0;
  for (const p of funcType.params) totalFlatParams += typeLayout(p.type).flat.length;
  const resultLayout = funcType.result ? typeLayout(funcType.result) : null;

  return (...highArgs) => {
    let flatArgs = [];
    if (totalFlatParams <= 16) {
      for (let i = 0; i < funcType.params.length; i++) {
        lowerFlatValue(funcType.params[i].type, highArgs[i], memory, realloc, flatArgs);
      }
    } else {
      throw new Error("Spilled >16 flat params not needed for knots:visual");
    }

    const rawRet = coreFunc(...flatArgs);
    if (!resultLayout) {
      if (postReturn) postReturn();
      return undefined;
    }

    let lifted;
    if (resultLayout.flat.length <= 1) {
      const view = memory ? new DataView(memory.buffer) : null;
      const bytes = memory ? new Uint8Array(memory.buffer) : null;
      lifted = liftFlatArgs(funcType.result, [rawRet], { i: 0 }, view, bytes);
      if (postReturn) postReturn(rawRet);
    } else {
      const retPtr = rawRet >>> 0;
      const view = new DataView(memory.buffer);
      const bytes = new Uint8Array(memory.buffer);
      lifted = loadFromMemory(funcType.result, view, bytes, retPtr);
      if (postReturn) postReturn(rawRet);
    }
    return lifted;
  };
}

function createCanonLower(compFuncHolder, funcType, memory, realloc) {
  const resultLayout = funcType.result ? typeLayout(funcType.result) : null;
  const indirectResult = resultLayout !== null && resultLayout.flat.length > 1;

  return (...coreArgs) => {
    const fn = typeof compFuncHolder === "function" ? compFuncHolder : compFuncHolder.fn;
    if (typeof fn !== "function") {
      throw new Error("Upstream WIT component interface is not linked");
    }
    const view = memory ? new DataView(memory.buffer) : null;
    const bytes = memory ? new Uint8Array(memory.buffer) : null;
    const cursor = { i: 0 };
    const highArgs = [];
    for (const p of funcType.params) {
      highArgs.push(liftFlatArgs(p.type, coreArgs, cursor, view, bytes));
    }
    const retPtr = indirectResult ? coreArgs[cursor.i++] >>> 0 : 0;
    const highRes = fn(...highArgs);
    if (!resultLayout) return undefined;
    if (!indirectResult) {
      const out = [];
      lowerFlatValue(funcType.result, highRes, memory, realloc, out);
      return out[0];
    }
    storeToMemory(funcType.result, highRes, memory, realloc, retPtr);
    return undefined;
  };
}

// ── Full WebAssembly Component Binary Instantiator (`\0asm \x0d\x00\x01\x00`) ──

export async function instantiateWasmComponent(rawBytes, importedInterfaces = {}) {
  const bytes = rawBytes instanceof Uint8Array ? rawBytes : new Uint8Array(rawBytes);
  if (bytes.byteLength < 8) throw new Error("Wasm binary too short");
  for (let i = 0; i < 4; i++) {
    if (bytes[i] !== WASM_MAGIC[i]) throw new Error("Invalid WebAssembly magic header");
  }
  if (bytes[4] === 0x01 && bytes[5] === 0x00 && bytes[6] === 0x00 && bytes[7] === 0x00) {
    throw new Error("Expected a WebAssembly Component (layer 0x01), got a core Wasm module");
  }
  for (let i = 0; i < 4; i++) {
    if (bytes[4 + i] !== COMPONENT_PREAMBLE[i]) {
      throw new Error("Unsupported WebAssembly Component version/layer");
    }
  }

  const coreModules = [];
  const coreInstances = [];
  const coreFuncs = [];
  const coreTables = [];
  const coreMemories = [];
  const coreGlobals = [];

  const compTypes = [];
  const compFuncs = [];
  const compInstances = [];
  const compExports = Object.create(null);
  const compImports = [];

  const outerScopes = [{ types: compTypes, instances: compInstances }];
  const top = new BinaryReader(bytes, 8, bytes.byteLength);

  while (top.remaining() > 0) {
    const sectionId = top.readByte();
    const sectionLen = top.readU32Leb();
    const sectionStart = top.pos;
    const sectionBytes = top.readBytes(sectionLen);
    const sec = new BinaryReader(sectionBytes, 0, sectionBytes.byteLength);

    switch (sectionId) {
      case 0: // custom
        break;
      case 1: {
        // core:module (payload is a single core .wasm binary)
        const mod = await WebAssembly.compile(
          bytes.buffer.slice(
            bytes.byteOffset + sectionStart,
            bytes.byteOffset + sectionStart + sectionLen,
          ),
        );
        coreModules.push(mod);
        break;
      }
      case 2: {
        // core:instance
        const count = sec.readU32Leb();
        for (let i = 0; i < count; i++) {
          const kind = sec.readByte();
          if (kind === 0x00) {
            const modIdx = sec.readU32Leb();
            const argCount = sec.readU32Leb();
            const importObj = Object.create(null);
            for (let a = 0; a < argCount; a++) {
              const argName = sec.readName();
              const argKind = sec.readByte();
              const instIdx = sec.readU32Leb();
              if (argKind !== 0x12) {
                throw new Error(`Unsupported core instantiate arg kind 0x${argKind.toString(16)}`);
              }
              importObj[argName] = coreInstances[instIdx].exports;
            }
            const inst = await WebAssembly.instantiate(coreModules[modIdx], importObj);
            coreInstances.push(inst);
          } else if (kind === 0x01) {
            const expCount = sec.readU32Leb();
            const exportsObj = Object.create(null);
            for (let e = 0; e < expCount; e++) {
              const name = sec.readName();
              const sortByte = sec.readByte();
              const idx = sec.readU32Leb();
              if (sortByte === 0x00) exportsObj[name] = coreFuncs[idx];
              else if (sortByte === 0x01) exportsObj[name] = coreTables[idx];
              else if (sortByte === 0x02) exportsObj[name] = coreMemories[idx];
              else if (sortByte === 0x03) exportsObj[name] = coreGlobals[idx];
              else throw new Error(`Unsupported core inline export sort 0x${sortByte.toString(16)}`);
            }
            coreInstances.push({ exports: exportsObj });
          } else {
            throw new Error(`Unsupported core:instance kind 0x${kind.toString(16)}`);
          }
        }
        break;
      }
      case 5: {
        // component instance
        const count = sec.readU32Leb();
        for (let i = 0; i < count; i++) {
          const kind = sec.readByte();
          if (kind === 0x01) {
            const expCount = sec.readU32Leb();
            const instObj = {
              exports: Object.create(null),
              exportedTypes: Object.create(null),
              exportedFuncs: Object.create(null),
            };
            for (let e = 0; e < expCount; e++) {
              const name = sec.readExternName();
              const sort = readSort(sec);
              const idx = sec.readU32Leb();
              if (sort.kind === "func") {
                instObj.exports[name] = compFuncs[idx].fn;
                instObj.exportedFuncs[name] = compFuncs[idx];
              } else if (sort.kind === "type") {
                instObj.exportedTypes[name] = compTypes[idx];
              } else if (sort.kind === "instance") {
                instObj.exports[name] = compInstances[idx];
              }
            }
            compInstances.push(instObj);
          } else {
            throw new Error(`Nested component instantiation (kind 0x${kind.toString(16)}) unsupported`);
          }
        }
        break;
      }
      case 6: {
        // alias
        const count = sec.readU32Leb();
        for (let i = 0; i < count; i++) {
          const sort = readSort(sec);
          const target = sec.readByte();
          if (target === 0x00) {
            // component instance export
            const instIdx = sec.readU32Leb();
            const name = sec.readName();
            const inst = compInstances[instIdx];
            if (sort.kind === "type") {
              compTypes.push(inst?.exportedTypes?.[name] ?? inst?.typeDef?.exportedTypes?.[name]);
            } else if (sort.kind === "func") {
              const funcType = inst?.typeDef?.exportedFuncs?.[name] ?? null;
              const holder = inst?.holders?.[name] ?? {
                fn: inst?.exports?.[name] ?? null,
                type: funcType,
              };
              compFuncs.push(holder);
            } else if (sort.kind === "instance") {
              compInstances.push(inst?.exports?.[name]);
            }
          } else if (target === 0x01) {
            // core instance export
            const coreInstIdx = sec.readU32Leb();
            const name = sec.readName();
            const item = coreInstances[coreInstIdx].exports[name];
            if (sort.kind === "func") coreFuncs.push(item);
            else if (sort.kind === "table") coreTables.push(item);
            else if (sort.kind === "memory") coreMemories.push(item);
            else if (sort.kind === "global") coreGlobals.push(item);
          } else if (target === 0x02) {
            const depth = sec.readU32Leb();
            const idx = sec.readU32Leb();
            const scope = outerScopes[depth];
            if (sort.kind === "type") compTypes.push(scope.types[idx]);
            else if (sort.kind === "instance") compInstances.push(scope.instances[idx]);
          } else {
            throw new Error(`Unsupported alias target 0x${target.toString(16)}`);
          }
        }
        break;
      }
      case 7: {
        // type
        const count = sec.readU32Leb();
        for (let i = 0; i < count; i++) {
          compTypes.push(parseDefType(sec, compTypes, outerScopes));
        }
        break;
      }
      case 8: {
        // canon
        const count = sec.readU32Leb();
        for (let i = 0; i < count; i++) {
          const op = sec.readByte();
          const sub = sec.readByte();
          if (op === 0x00 && sub === 0x00) {
            // canon lift
            const coreFuncIdx = sec.readU32Leb();
            const opts = readCanonOpts(sec);
            const typeIdx = sec.readU32Leb();
            const funcType = compTypes[typeIdx];
            const mem = opts.memory !== null ? coreMemories[opts.memory] : null;
            const realloc = opts.realloc !== null ? coreFuncs[opts.realloc] : null;
            const postReturn = opts.postReturn !== null ? coreFuncs[opts.postReturn] : null;
            const lifted = createCanonLift(coreFuncs[coreFuncIdx], funcType, mem, realloc, postReturn);
            compFuncs.push({ fn: lifted, type: funcType });
          } else if (op === 0x01 && sub === 0x00) {
            // canon lower
            const compFuncIdx = sec.readU32Leb();
            const opts = readCanonOpts(sec);
            const holder = compFuncs[compFuncIdx];
            const mem = opts.memory !== null ? coreMemories[opts.memory] : null;
            const realloc = opts.realloc !== null ? coreFuncs[opts.realloc] : null;
            const lowered = createCanonLower(holder, holder.type, mem, realloc);
            coreFuncs.push(lowered);
          } else {
            throw new Error(`Unsupported canon op 0x${op.toString(16)}/0x${sub.toString(16)}`);
          }
        }
        break;
      }
      case 10: {
        // import
        const count = sec.readU32Leb();
        for (let i = 0; i < count; i++) {
          const name = sec.readExternName();
          const desc = readExternDesc(sec, compTypes);
          compImports.push({ name, kind: desc.kind });
          if (desc.kind === "instance") {
            const instType = compTypes[desc.idx];
            const supplied = importedInterfaces[name] ?? findMatchingInterface(importedInterfaces, name) ?? {};
            const holders = Object.create(null);
            if (instType?.exportedFuncs) {
              for (const [fnName, fnType] of Object.entries(instType.exportedFuncs)) {
                holders[fnName] = {
                  get fn() {
                    return supplied[fnName];
                  },
                  type: fnType,
                };
              }
            }
            compInstances.push({
              name,
              typeDef: instType,
              exportedTypes: instType?.exportedTypes ?? Object.create(null),
              exports: supplied,
              holders,
            });
          } else if (desc.kind === "type") {
            compTypes.push(desc.bound === "eq" ? compTypes[desc.idx] : { kind: "resource", name });
          } else if (desc.kind === "func") {
            const fnType = compTypes[desc.idx];
            compFuncs.push({
              get fn() {
                return importedInterfaces[name];
              },
              type: fnType,
            });
          }
        }
        break;
      }
      case 11: {
        // export
        const count = sec.readU32Leb();
        for (let i = 0; i < count; i++) {
          const name = sec.readExternName();
          const sort = readSort(sec);
          const idx = sec.readU32Leb();
          const hasDesc = sec.readByte();
          if (hasDesc === 0x01) readExternDesc(sec, compTypes);
          if (sort.kind === "instance") {
            const inst = compInstances[idx];
            compInstances.push(inst);
            compExports[name] = inst.exports;
          } else if (sort.kind === "func") {
            const fnHolder = compFuncs[idx];
            compFuncs.push(fnHolder);
            compExports[name] = fnHolder.fn;
          } else if (sort.kind === "type") {
            const ty = compTypes[idx];
            compTypes.push(ty);
          }
        }
        break;
      }
      default:
        break;
    }
  }

  return {
    exports: compExports,
    imports: compImports,
    memories: coreMemories,
    memoryBytes() {
      let total = 0;
      for (const m of coreMemories) total += m.buffer.byteLength;
      return total;
    },
  };
}

function findMatchingInterface(map, requestedName) {
  if (map[requestedName]) return map[requestedName];
  const base = requestedName.split("@")[0];
  for (const [k, v] of Object.entries(map)) {
    if (k === base || k.split("@")[0] === base) return v;
  }
  return null;
}

function findExportedSource(exportsObj) {
  for (const [k, v] of Object.entries(exportsObj)) {
    if (k.startsWith(SOURCE_INTERFACE_PREFIX) && v && typeof v.describe === "function") {
      return v;
    }
  }
  return null;
}

// ── Dynamic Slot Manager & Runtime Generator -> Effect Linker ──

export class WasmComponentHost {
  constructor(knotsHost) {
    this.knotsHost = knotsHost;
    // Slot 0 = Generator, Slot 1 = Effect
    this.slots = [null, null];
    this.eventCallback = null;
    this.upstreamProxy = this.createUpstreamProxy();
  }

  createUpstreamProxy() {
    const self = this;
    return {
      describe() {
        const gen = self.slots[0]?.source;
        if (!gen) throw new Error("No upstream generator component loaded");
        return gen.describe();
      },
      "render-vector"(ctx) {
        const gen = self.slots[0]?.source;
        if (!gen) return { __rawShapes: new Uint8Array(0), length: 0 };
        return gen["render-vector"](ctx);
      },
      "render-pixels"(ctx) {
        const gen = self.slots[0]?.source;
        if (!gen) return { width: 0, height: 0, rgba: new Uint8Array(0) };
        return gen["render-pixels"](ctx);
      },
    };
  }

  setEventCallback(cb) {
    this.eventCallback = typeof cb === "function" ? cb : null;
  }

  notify(slot, ok, label, byteLen, loadMicros, errorMsg) {
    if (this.eventCallback) {
      this.eventCallback(slot >>> 0, Boolean(ok), String(label), byteLen >>> 0, Number(loadMicros), String(errorMsg ?? ""));
    }
    this.knotsHost?.requestFrame?.();
  }

  async loadBytes(slot, label, rawBytes, autoRouteByImports = false) {
    const t0 = globalThis.performance ? performance.now() : Date.now();
    try {
      const bytes = rawBytes instanceof Uint8Array ? rawBytes : new Uint8Array(rawBytes);
      const imported = {
        "knots:visual/upstream@0.1.0": this.upstreamProxy,
        "knots:visual/source@0.1.0": this.upstreamProxy,
      };
      const instance = await instantiateWasmComponent(bytes, imported);
      const source = findExportedSource(instance.exports);
      if (!source) {
        throw new Error("Component does not export knots:visual/source@0.1.0");
      }

      const info = source.describe();
      const importsSource = instance.imports.some(
        (im) =>
          im.kind === "instance" &&
          (im.name.startsWith(UPSTREAM_INTERFACE_PREFIX) || im.name.startsWith(SOURCE_INTERFACE_PREFIX)),
      );

      let targetSlot = slot >>> 0;
      if (autoRouteByImports) {
        targetSlot = importsSource || info.role === 1 ? 1 : 0;
      } else if (targetSlot === 0 && importsSource) {
        throw new Error("This component imports knots:visual/source (load it in the Effect slot)");
      }

      const elapsedUs = ((globalThis.performance ? performance.now() : Date.now()) - t0) * 1000.0;
      this.slots[targetSlot] = {
        label,
        bytes,
        instance,
        source,
        info,
        importsSource,
        loadMicros: elapsedUs,
      };
      this.notify(targetSlot, true, label, bytes.byteLength, elapsedUs, "");
      return targetSlot;
    } catch (err) {
      const elapsedUs = ((globalThis.performance ? performance.now() : Date.now()) - t0) * 1000.0;
      const msg = err instanceof Error ? err.message : String(err);
      this.notify(slot >>> 0, false, label, 0, elapsedUs, msg);
      throw err;
    }
  }

  loadUrl(slot, url) {
    const label = String(url).split("/").pop() || String(url);
    fetch(url)
      .then(async (resp) => {
        if (!resp.ok) throw new Error(`HTTP ${resp.status} fetching ${url}`);
        return new Uint8Array(await resp.arrayBuffer());
      })
      .then((bytes) => this.loadBytes(slot, label, bytes, false))
      .catch(() => {});
  }

  openFilePicker(slot) {
    if (typeof document === "undefined") return;
    const input = document.createElement("input");
    input.type = "file";
    input.accept = ".wasm,application/wasm";
    input.style.display = "none";
    input.addEventListener("change", () => {
      const file = input.files?.[0];
      input.remove();
      if (!file) return;
      file
        .arrayBuffer()
        .then((buf) => this.loadBytes(slot, file.name, new Uint8Array(buf), slot > 1))
        .catch(() => {});
    });
    document.body.appendChild(input);
    input.click();
  }

  installDragAndDrop(canvasSelector = "#canvas") {
    if (typeof document === "undefined") return;
    const target = document.querySelector(canvasSelector) ?? globalThis.window;
    if (!target?.addEventListener) return;
    target.addEventListener("dragover", (ev) => {
      ev.preventDefault();
    });
    target.addEventListener("drop", (ev) => {
      const files = ev.dataTransfer?.files;
      if (!files || files.length === 0) return;
      for (const file of files) {
        if (file.name.endsWith(".wasm")) {
          ev.preventDefault();
          file
            .arrayBuffer()
            .then((buf) => this.loadBytes(0, file.name, new Uint8Array(buf), true))
            .catch(() => {});
        }
      }
    });
  }

  unload(slot) {
    const idx = slot >>> 0;
    if (idx < this.slots.length) {
      this.slots[idx] = null;
      this.notify(idx, true, "", 0, 0, "");
    }
  }

  copySlotBytes(slot, destBytes) {
    const entry = this.slots[slot >>> 0];
    if (!entry || !destBytes) return 0;
    const n = Math.min(entry.bytes.byteLength, destBytes.byteLength);
    destBytes.set(entry.bytes.subarray(0, n), 0);
    return n;
  }

  getMetadataJson(slot) {
    const entry = this.slots[slot >>> 0];
    if (!entry) return "";
    const info = entry.info;
    const params = (info.params ?? []).map((p) => ({
      name: p.name,
      min_val: p["min-val"],
      max_val: p["max-val"],
      default_val: p["default-val"],
      step: p.step,
    }));
    return JSON.stringify({
      id: info.id,
      title: info.title,
      summary: info.summary,
      role: info.role,
      preferred_output: info["preferred-output"],
      memory_bytes: entry.instance.memoryBytes(),
      params,
    });
  }

  activeEntry() {
    if (this.slots[1] && this.slots[0]) return this.slots[1];
    return this.slots[0] ?? null;
  }

  decodeParams(paramsBytes) {
    if (!paramsBytes || paramsBytes.byteLength < 4) return new Float32Array(0);
    const count = paramsBytes.byteLength >>> 2;
    const view = new DataView(paramsBytes.buffer, paramsBytes.byteOffset, paramsBytes.byteLength);
    const out = new Float32Array(count);
    for (let i = 0; i < count; i++) out[i] = view.getFloat32(i * 4, true);
    return out;
  }

  writeStats(outStatsBytes, execMicros) {
    if (!outStatsBytes || outStatsBytes.byteLength < 12) return;
    const view = new DataView(outStatsBytes.buffer, outStatsBytes.byteOffset, outStatsBytes.byteLength);
    view.setFloat32(0, execMicros, true);
    view.setUint32(4, this.slots[0]?.instance.memoryBytes() ?? 0, true);
    view.setUint32(8, this.slots[1]?.instance.memoryBytes() ?? 0, true);
  }

  renderVectorFrame(
    timeSec,
    deltaSec,
    width,
    height,
    pointerX,
    pointerY,
    pointerDown,
    paramsBytes,
    outShapesBytes,
    outStatsBytes,
  ) {
    const top = this.activeEntry();
    if (!top) return 0;

    const t0 = globalThis.performance ? performance.now() : Date.now();
    const ctx = {
      "time-sec": Number(timeSec),
      "delta-sec": Number(deltaSec),
      width: width >>> 0,
      height: height >>> 0,
      "pointer-x": Number(pointerX),
      "pointer-y": Number(pointerY),
      "pointer-down": Boolean(pointerDown),
      params: this.decodeParams(paramsBytes),
    };
    const result = top.source["render-vector"](ctx);
    const elapsedUs = ((globalThis.performance ? performance.now() : Date.now()) - t0) * 1000.0;
    this.writeStats(outStatsBytes, elapsedUs);

    if (result && result.__rawShapes instanceof Uint8Array) {
      const maxShapes = Math.floor(outShapesBytes.byteLength / SHAPE_BYTE_STRIDE);
      const count = Math.min(result.length >>> 0, maxShapes);
      outShapesBytes.set(result.__rawShapes.subarray(0, count * SHAPE_BYTE_STRIDE), 0);
      return count;
    }
    return 0;
  }

  renderPixelFrame(
    timeSec,
    deltaSec,
    width,
    height,
    pointerX,
    pointerY,
    pointerDown,
    paramsBytes,
    outRgbaBytes,
    outMetaBytes,
  ) {
    const top = this.activeEntry();
    if (!top) return 0;

    const t0 = globalThis.performance ? performance.now() : Date.now();
    const ctx = {
      "time-sec": Number(timeSec),
      "delta-sec": Number(deltaSec),
      width: width >>> 0,
      height: height >>> 0,
      "pointer-x": Number(pointerX),
      "pointer-y": Number(pointerY),
      "pointer-down": Boolean(pointerDown),
      params: this.decodeParams(paramsBytes),
    };
    const pf = top.source["render-pixels"](ctx);
    const elapsedUs = ((globalThis.performance ? performance.now() : Date.now()) - t0) * 1000.0;

    const pw = pf?.width >>> 0;
    const ph = pf?.height >>> 0;
    const rgba = pf?.rgba;
    const needed = pw * ph * 4;

    if (outMetaBytes && outMetaBytes.byteLength >= 20) {
      const mv = new DataView(outMetaBytes.buffer, outMetaBytes.byteOffset, outMetaBytes.byteLength);
      mv.setUint32(0, pw, true);
      mv.setUint32(4, ph, true);
      mv.setFloat32(8, elapsedUs, true);
      mv.setUint32(12, this.slots[0]?.instance.memoryBytes() ?? 0, true);
      mv.setUint32(16, this.slots[1]?.instance.memoryBytes() ?? 0, true);
    }

    if (!rgba || needed === 0 || needed > outRgbaBytes.byteLength || rgba.byteLength < needed) {
      return 0;
    }
    outRgbaBytes.set(rgba.subarray(0, needed), 0);
    return needed;
  }
}

export async function installMain({ host }) {
  const manager = new WasmComponentHost(host);
  manager.installDragAndDrop("#canvas");
  host.wasmComponents = manager;
}
