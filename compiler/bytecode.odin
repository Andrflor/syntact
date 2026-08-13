package compiler

import bc "bytecode"
import "core:fmt"

// LOWERING — reduced IR (^Type DAG) → the neutral bytecode (package `bytecode`).
// The one codegen part that must know both worlds, so it lives in package compiler.
// Memoization keyed by node ADDRESS carries the reducer's CSE through: a node
// reached twice returns the same vN.

// op_to_bc maps Operator_Kind to BC_Op. Unmapped operators fall back to Add and
// are guarded upstream (non-arithmetic operators don't reach lowering).
op_to_bc :: proc(op: Operator_Kind) -> bc.BC_Op {
	#partial switch op {
	case .Add:
		return .Add
	case .Subtract:
		return .Subtract
	case .Multiply:
		return .Multiply
	case .Divide:
		return .Divide
	case .Mod:
		return .Mod
	case .And, .BitAnd:
		return .BitAnd
	case .Or, .BitOr:
		return .BitOr
	case .Xor:
		return .BitXor
	case .LShift:
		return .LShift
	case .RShift:
		return .RShift
	case .Equal:
		return .Equal
	case .NotEqual:
		return .NotEqual
	case .Less:
		return .Less
	case .Greater:
		return .Greater
	case .LessEqual:
		return .LessEqual
	case .GreaterEqual:
		return .GreaterEqual
	}
	return .Add
}

// machine_type_of derives a reduced node's Machine_Type. Single point of truth for
// the int/float width-and-signedness mapping. .None = no materializable layout yet
// (unsized int/float, symbolic string), which the caller rejects.
machine_type_of :: proc(node: ^Type) -> bc.Machine_Type {
	if node == nil do return .None
	#partial switch v in node^ {
	case Integer_Type:
		if int_is_concrete(v) {
			return bc.mtype_for_int_value(i64(int_value(v)))
		}
		if len(v.integer_intervals) == 1 {
			iv := v.integer_intervals[0]
			if lay, ok := int_layout(iv); ok {
				return bc.mtype_from_layout(lay.bits, lay.signed)
			}
			// Non-canonical range: smallest type that contains it (known by construction).
			lo, hi: Maybe(i64)
			if l, lok := iv.lo.?; lok do lo = i64(l)
			if h, hok := iv.hi.?; hok do hi = i64(h)
			return bc.mtype_for_range(lo, hi)
		}
		return .I64
	case Float_Type:
		switch v.kind {
		case .f32:
			return .F32
		case .f64:
			return .F64
		case .none:
			return .F64
		}
	case Bool_Type:
		return .U8
	case String_Type:
		if string_is_concrete(v) do return .Str
		return .None
	case Cast_Type:
		if tgt, ok := cast_target(v.target); ok {
			switch tgt.kind {
			case .Integer:
				return bc.mtype_from_layout(tgt.width, tgt.signed)
			case .Float:
				return tgt.float_kind == .f32 ? .F32 : .F64
			case .Bool:
				return .U8
			case .String, .Char:
				return .Str
			}
		}
		return .None
	case Compose_Type:
		if env := fold_type(node); env != nil && env != node {
			return machine_type_of(env)
		}
		lm := machine_type_of(v.left)
		rm := machine_type_of(v.right)
		return bc.mtype_wider(lm, rm)
	case Foreign_Call_Type:
		// An external's layout is its DECLARED production: nothing else about the
		// result is knowable at compile time.
		return machine_type_of(v.production)
	case Effect_Sequence_Type:
		return machine_type_of(v.value)
	}
	return .None
}

BC_Lower :: struct {
	prog: ^bc.BC_Program,
	memo: map[^Type]bc.BC_Value, // DAG node → its already-lowered vN (CSE)
	// During terminal recursion this maps the enclosing binding sites to their
	// loop-carried virtual values. It is intentionally local to lowering: it is
	// not a language-level environment or an address-bearing value.
	frame: map[BC_Binding_Key]bc.BC_Value,
	frame_slots: map[int]bc.BC_Value,
	registry: ^bc.BC_Program,
	functions: map[rawptr]bc.Func_Id,
	function_done: map[rawptr]bool,
	aggregate_frames: map[BC_Binding_Key]BC_Aggregate_Frame,
	current_scope: ^Scope_Type,
}

BC_Binding_Key :: struct {
	scope: rawptr,
	index: int,
}

// An aggregate parameter is represented internally by an abstract scratch
// address. This is backend metadata only: no source expression can observe it.
BC_Aggregate_Frame :: struct {
	address: bc.BC_Value,
	scope:   ^Scope_Type,
}

bc_fresh_value :: proc(l: ^BC_Lower, mt: bc.Machine_Type = .I64) -> bc.BC_Value {
	v := bc.BC_Value(l.prog.value_count)
	l.prog.value_count += 1
	append(&l.prog.value_types, mt)
	return v
}

bc_fail :: proc(l: ^BC_Lower, msg: string) -> bc.BC_Value {
	if l.prog.error == "" do l.prog.error = msg
	return bc_fresh_value(l)
}

bc_fresh_label :: proc(l: ^BC_Lower) -> bc.BC_Label {
	lab := bc.BC_Label(l.prog.label_count)
	l.prog.label_count += 1
	return lab
}

bc_emit :: proc(l: ^BC_Lower, inst: bc.BC_Inst) {
	append(&l.prog.insts, inst)
}

// lower_to_bytecode turns the reduced DAG into the neutral bytecode every backend
// shares. `root` is the value the main scope reduces to (reduce(scope)).
lower_to_bytecode :: proc(root: ^Type) -> ^bc.BC_Program {
	if root == nil do return nil
	prog := new(bc.BC_Program)
	l := BC_Lower {
		prog = prog,
		memo = make(map[^Type]bc.BC_Value),
		frame = make(map[BC_Binding_Key]bc.BC_Value),
		frame_slots = make(map[int]bc.BC_Value),
		registry = prog,
		functions = make(map[rawptr]bc.Func_Id),
		function_done = make(map[rawptr]bool),
		aggregate_frames = make(map[BC_Binding_Key]BC_Aggregate_Frame),
		current_scope = nil,
	}
	defer delete(l.memo)
	defer delete(l.frame)
	defer delete(l.frame_slots)
	defer delete(l.functions)
	defer delete(l.function_done)
	defer delete(l.aggregate_frames)
	// Reserve the entry identity before any body can create a callee.
	append(&prog.funcs, bc.BC_Func{id = 0, identity = "main"})
	result := bc_lower_value(&l, root)
	prog.result_type = machine_type_of(root)
	root_aggregate_result := false
	if fc, ok := root^.(Foreign_Call_Type); ok {
		if bc_declared_aggregate(fc.production) {
			root_aggregate_result = true
			prog.error = "codegen: aggregate program results have no scalar process-result channel"
			prog.result_type = .None
		}
		if len(fc.writebacks) > 0 {
			// The nominal event continuation is the value of the expression, just as a
			// static emit reduces to its named handler's production.
			if int(result) < len(prog.value_types) do prog.result_type = prog.value_types[result]
		}
	}
	if !root_aggregate_result && prog.result_type == .None && int(result) < len(prog.value_types) {
		prog.result_type = prog.value_types[int(result)]
	}
	if root_aggregate_result do prog.result_type = .None
	bc_emit(&l, bc.BC_Ret{result})
	// Keep one named entry function available to consumers that use the function
	// model. The flat fields remain authoritative for the existing x64 path.
	bc_publish_legacy_entry(prog)
	// Affine canonicalization happens upstream in the reducer; bytecode is minimal.
	return prog
}

bc_publish_legacy_entry :: proc(prog: ^bc.BC_Program) {
	fn := bc.BC_Func {
		id = 0,
		identity = "main",
		result = prog.result_type,
		result_layout = prog.result_layout,
		has_result_layout = prog.has_result_layout,
		sret_slot = prog.sret_slot,
		insts = prog.insts[:],
		value_count = prog.value_count,
		label_count = prog.label_count,
		value_types = prog.value_types[:],
		loops = prog.loops[:],
		scratch = prog.scratch[:],
	}
	if len(prog.funcs) == 0 {
		append(&prog.funcs, fn)
	} else {
		prog.funcs[0] = fn
	}
	prog.entry = 0
}

bc_lower_value :: proc(l: ^BC_Lower, node: ^Type) -> bc.BC_Value {
	if node == nil {
		dst := bc_fresh_value(l)
		bc_emit(l, bc.BC_Const{dst, 0})
		return dst
	}
	if key, ok := bc_binding_key(node); ok {
		is_capture := false
		#partial switch _ in node^ {
		case Mention_Type, Recursive_Mention_Type:
			is_capture = true
		}
		if is_capture {
			if frame, found := l.aggregate_frames[key]; found do return frame.address
			if value, found := l.frame[key]; found do return value
			if value, found := l.frame_slots[key.index]; found do return value
		}
	}
	// Pure DAG nodes may be CSE'd. Foreign calls and residual sequences are
	// effectful, so sharing their node must not erase a second execution.
	memoizable := !holds_foreign_collapse(node)
	if memoizable {
		if v, ok := l.memo[node]; ok do return v
	}

	dst: bc.BC_Value
	#partial switch v in node^ {
	case Integer_Type:
		if int_is_concrete(v) {
			dst = bc_fresh_value(l, .I64)
			bc_emit(l, bc.BC_Const{dst, i64(int_value(v))})
		} else {
			dst = bc_lower_fixed_point(l, node)
		}

	case Float_Type:
		if float_is_concrete(v) {
			dst = bc_fresh_value(l, machine_type_of(node))
			bc_emit(l, bc.BC_Const_F{dst, float_value(v)})
		} else {
			dst = bc_lower_fixed_point(l, node)
		}

	case Bool_Type:
		dst = bc_fresh_value(l, .U8)
		bc_emit(l, bc.BC_Const{dst, bool_is_concrete(v) && bool_value(v) ? 1 : 0})

	case None_Type:
		// Empty set / absence of a value (e.g. `true & false`) materializes as 0.
		dst = bc_fresh_value(l, .I64)
		bc_emit(l, bc.BC_Const{dst, 0})

	case String_Type:
		if string_is_concrete(v) {
			dst = bc_lower_string_const(l, string_value(v))
		} else {
			dst = bc_fail(l, "codegen: symbolic string not yet supported (needs pattern capture)")
		}

	case Cast_Type:
		dst = bc_lower_fixed_point(l, node)

	case Unknown_Type:
		dst = bc_lower_fixed_point(l, node)

	case Compose_Type:
		// A string-domain compose is an ordered sequence, not arithmetic (needs
		// pattern capture, not yet implemented). Reject before lowering operands.
		if bc_compose_is_string(node) {
			dst = bc_fail(
				l,
				"codegen: symbolic string concatenation not yet supported (needs pattern capture)",
			)
		} else {
			dst = bc_lower_compose(l, node, v)
		}

	case Pattern_Type:
		dst = bc_lower_pattern(l, v)

	case Foreign_Call_Type:
		dst = bc_lower_foreign_call(l, node, v)

	case Effect_Sequence_Type:
		for effect in v.effects do _ = bc_lower_value(l, effect)
		dst = bc_lower_value(l, v.value)

	case Execute_Type:
		if carve, ok := bc_execute_carve(v.target); ok {
			dst = bc_lower_internal_call(l, carve)
		} else {
			dst = bc_fail(l, "codegen: unsupported collapse in lowering")
		}

	case Carve_Type:
		// A direct collapse product may be represented as Carve after reduction
		// (the Execute wrapper is not retained in every residual path).
		carve := v
		dst = bc_lower_internal_call(l, &carve)

	case Mention_Type, Recursive_Mention_Type:
		resolved := follow(node)
		if resolved != nil && resolved != node {
			dst = bc_lower_value(l, resolved)
		} else {
			dst = bc_fail(l, "codegen: unresolved reference in lowering")
		}

	case Reference_Type:
		if loaded, ok := bc_lower_aggregate_reference(l, v); ok {
			dst = loaded
		} else {
			resolved := follow(node)
			if resolved != nil && resolved != node {
				dst = bc_lower_value(l, resolved)
			} else {
				dst = bc_fail(l, "codegen: unresolved reference in lowering")
			}
		}

	case Scope_Type:
		scope := v
		found := false
		for i in 0 ..< len(scope.kind) {
			if scope.kind[i] == .Product {
				dst = bc_lower_value(l, reduce_slot_value(&scope, i))
				found = true
				break
			}
		}
		if !found do dst = bc_fail(l, "codegen: empty structural scope in lowering")

	case:
		dst = bc_fail(l, fmt.tprintf("codegen: unsupported value (%s) in lowering", bc_type_kind(node)))
	}

	if memoizable do l.memo[node] = dst
	return dst
}

bc_type_kind :: proc(node: ^Type) -> string {
	if node == nil do return "nil"
	#partial switch v in node^ {
	case Or_Type: return "or"
	case And_Type: return "and"
	case Negate_Type: return "negate"
	case Compose_Type: return "compose"
	case Cast_Type: return "cast"
	case String_Type: return "string"
	case Scope_Type: return "scope"
	case Integer_Type: return "integer"
	case Float_Type: return "float"
	case Execute_Type: return "execute"
	case Foreign_Call_Type: return "foreign"
	case Effect_Sequence_Type: return "effects"
	case Range_Type: return "range"
	case Bool_Type: return "bool"
	case None_Type: return "none"
	case Invalid_Type: return "invalid"
	case Unknown_Type: return "unknown"
	case Carve_Type: return "carve"
	case Mention_Type: return "mention"
	case Reference_Type: return "reference"
	case Recursive_Mention_Type: return "recursive-mention"
	case Pattern_Type: return "pattern"
	}
	return "?"
}

bc_binding_key :: proc(node: ^Type) -> (BC_Binding_Key, bool) {
	if node == nil do return {}, false
	#partial switch v in node^ {
	case Mention_Type:
		if v.match_scope != nil && v.match_index >= 0 do return {rawptr(scope_canon(v.match_scope)), v.match_index}, true
	case Reference_Type:
		if v.reference != nil && v.reference.match_scope != nil && v.reference.match_index >= 0 {
			return {rawptr(scope_canon(v.reference.match_scope)), v.reference.match_index}, true
		}
	case Recursive_Mention_Type:
		if v.match_scope != nil && v.match_index >= 0 do return {rawptr(scope_canon(v.match_scope)), v.match_index}, true
	}
	return {}, false
}

// A handler capture is passed as an abstract aggregate address. Property reads
// from that capture become indirect scalar loads; aggregate property values are
// deliberately rejected until a byte-copy continuation is required there too.
bc_lower_aggregate_reference :: proc(l: ^BC_Lower, v: Reference_Type) -> (bc.BC_Value, bool) {
	if v.target == nil || v.reference == nil do return {}, false
	key, ok := bc_binding_key(v.target)
	if !ok do return {}, false
	frame, found := l.aggregate_frames[key]
	if !found || frame.scope == nil {
		if target_ref, is_ref := v.target^.(Reference_Type); is_ref {
			address, address_ok := bc_lower_aggregate_reference(l, target_ref)
			if address_ok {
				frame = BC_Aggregate_Frame{address = address, scope = nil}
				if target_type := follow(v.target); target_type != nil {
					if nested, nested_ok := &target_type^.(Scope_Type); nested_ok do frame.scope = nested
				}
			}
		}
	}
	if frame.scope == nil do return {}, false
	field_scope := v.reference.match_scope
	field_index := v.reference.match_index
	if field_scope == nil || field_index < 0 do return {}, false
	if scope_canon(field_scope) != scope_canon(frame.scope) do return {}, false

	layout, has_layout := c_layout(frame.scope)
	if !has_layout do return bc_fail(l, "codegen: aggregate event capture has no static layout"), true
	field_no := 0
	field_layout: C_Field_Layout
	for i in 0 ..< len(frame.scope.kind) {
		if frame.scope.kind[i] == .Product || frame.scope.kind[i] == .Expand do continue
		if i == field_index {
			if field_no >= len(layout.fields) do return bc_fail(l, "codegen: aggregate event field layout is inconsistent"), true
			field_layout = layout.fields[field_no]
			break
		}
		field_no += 1
	}
	if field_no >= len(layout.fields) do return {}, false
	if field_layout.indirect {
		return bc_fail(l, "codegen: aggregate handler fields cannot load borrowed indirect members"), true
	}
	if field_layout.size > 8 {
		dst := bc_fresh_value(l, .U64)
		if field_layout.offset == 0 {
			bc_emit(l, bc.BC_Move{dst = dst, src = frame.address})
		} else {
			bc_emit(l, bc.BC_Bin_Imm{dst = dst, op = .Add, a = frame.address, imm = i64(field_layout.offset)})
		}
		return dst, true
	}
	value := reduce_slot_value(field_scope, field_index)
	mt := machine_type_of(value)
	if mt == .None || bc.mtype_bits(mt) == 0 {
		return bc_fail(l, "codegen: aggregate handler field has no scalar machine layout"), true
	}
	dst := bc_fresh_value(l, mt)
	bc_emit(l, bc.BC_Load_Indirect{
		dst = dst,
		address = frame.address,
		offset = field_layout.offset,
		width = uint(field_layout.size * 8),
		signed = bc.mtype_signed(mt),
	})
	return dst, true
}

bc_execute_carve :: proc(target: ^Type) -> (^Carve_Type, bool) {
	if target == nil do return nil, false
	cur := follow(target)
	if cur == nil do return nil, false
	if carve, ok := &cur^.(Carve_Type); ok do return carve, true
	return nil, false
}

bc_source_identity :: proc(source: ^Type) -> string {
	if source != nil {
		#partial switch v in source^ {
		case Mention_Type:
			if v.name != "" do return v.name
		case Recursive_Mention_Type:
			if v.name != "" do return v.name
		case Reference_Type:
			if v.reference != nil {
				if name, ok := v.reference.name.?; ok && name != "" do return name
			}
		}
	}
	return "<anonymous>"
}

bc_lower_internal_call :: proc(l: ^BC_Lower, carve: ^Carve_Type) -> bc.BC_Value {
	callee := collapse_source(carve.source)
	if callee == nil do return bc_fail(l, "codegen: internal call has no function scope")
	key := rawptr(scope_canon(callee))
	id, found := l.functions[key]
	if !found {
		id = bc.Func_Id(len(l.registry.funcs))
		l.functions[key] = id
		append(&l.registry.funcs, bc.BC_Func{id = id, identity = bc_source_identity(carve.source)})
	}

	args: [dynamic]bc.BC_Value
	arg_layouts: [dynamic]bc.BC_Aggregate_Layout
	for i in 0 ..< len(callee.kind) {
		if callee.kind[i] == .Product || callee.kind[i] == .Resonance_Pull do continue
		value: bc.BC_Value
		override := -1
		for ref, j in carve.references {
			if carve_ref_index(ref, callee) == i {override = j; break}
		}
		if override >= 0 && override < len(carve.types) {
			value = bc_lower_value(l, carve.types[override])
		} else {
			key := BC_Binding_Key{rawptr(scope_canon(callee)), i}
			if current, has := l.frame[key]; has {
				value = current
			} else {
				value = bc_lower_value(l, reduce_slot_value(callee, i))
			}
		}
		append(&args, value)
		declared := i < len(callee.constraints) ? callee.constraints[i] : nil
		if declared != nil && bc_declared_aggregate(declared) {
			layout, layout_ok, layout_msg := bc_aggregate_abi_layout(declared)
			if !layout_ok {
				_ = bc_fail(l, fmt.tprintf("codegen: internal aggregate argument %d has unsupported ABI layout: %s", i, layout_msg))
				return bc.BC_Value(l.prog.value_count - 1)
			}
			append(&arg_layouts, layout)
		} else {
			append(&arg_layouts, bc.BC_Aggregate_Layout{})
		}
	}

	if !l.function_done[key] {
		l.function_done[key] = true
		bc_lower_internal_function(l, callee, id)
	}
	result_type := bc_function_result_type(callee)
	result_layout: bc.BC_Aggregate_Layout
	has_result_layout := false
	if body, body_ok := bc_handler_body(callee); body_ok && bc_declared_aggregate(body) {
		layout, layout_ok, layout_msg := bc_aggregate_abi_layout(body)
		if !layout_ok do return bc_fail(l, fmt.tprintf("codegen: internal aggregate result has unsupported ABI layout: %s", layout_msg))
		result_layout, has_result_layout = layout, true
	}
	dst := bc_fresh_value(l, result_type)
	if has_result_layout {
		slot := bc_scratch_slot(l, result_layout.size, result_layout.align)
		bc_emit(l, bc.BC_Materialize{dst = dst, slot = slot, size = result_layout.size, borrowed = false})
		// BC_Materialize is also the neutral definition of the stable result home;
		// the call overwrites it with the returned aggregate pieces.
	}
	bc_emit(l, bc.BC_Call{dst = dst, func = id, args = args[:], arg_layouts = arg_layouts[:], result_layout = result_layout, has_result_layout = has_result_layout})
	return dst
}

bc_function_result_type :: proc(scope: ^Scope_Type) -> bc.Machine_Type {
	if body, ok := bc_handler_body(scope); ok {
		if bc_declared_aggregate(body) do return .U64
		mt := machine_type_of(body)
		if mt == .None do mt = machine_type_of(fold_type(body))
		return mt
	}
	return .I64
}

bc_handler_body :: proc(scope: ^Scope_Type) -> (^Type, bool) {
	if scope == nil do return nil, false
	for i in 0 ..< len(scope.kind) {
		if scope.kind[i] == .Product do return reduce_slot_value(scope, i), true
	}
	for i in 0 ..< len(scope.kind) {
		if scope.kind[i] == .Resonance_Pull do return reduce_slot_value(scope, i), true
	}
	return nil, false
}

bc_lower_internal_function :: proc(l: ^BC_Lower, scope: ^Scope_Type, id: bc.Func_Id) {
	tmp := new(bc.BC_Program)
	callee := BC_Lower {
		prog = tmp,
		memo = make(map[^Type]bc.BC_Value),
		frame = make(map[BC_Binding_Key]bc.BC_Value),
		frame_slots = make(map[int]bc.BC_Value),
		registry = l.registry,
		functions = l.functions,
		function_done = l.function_done,
		aggregate_frames = make(map[BC_Binding_Key]BC_Aggregate_Frame),
		current_scope = scope,
	}
	defer delete(callee.memo)
	defer delete(callee.frame)
	defer delete(callee.frame_slots)
	defer delete(callee.aggregate_frames)

	params: [dynamic]bc.Machine_Type
	param_layouts: [dynamic]bc.BC_Aggregate_Layout
	param_scratch: [dynamic]bc.BC_Scratch_Id
	for i in 0 ..< len(scope.kind) {
		if scope.kind[i] == .Product || scope.kind[i] == .Resonance_Pull do continue
		declared := i < len(scope.constraints) ? scope.constraints[i] : nil
		if declared == nil do declared = reduce_slot_value(scope, i)
		is_aggregate := bc_declared_aggregate(declared)
		mt := is_aggregate ? bc.Machine_Type.U64 : machine_type_of(declared)
		if mt == .None do mt = machine_type_of(reduce_slot_value(scope, i))
		if mt == .None do mt = .I64
		append(&params, mt)
		if is_aggregate {
			layout, layout_ok, layout_msg := bc_aggregate_abi_layout(declared)
			if !layout_ok {
				l.prog.error = fmt.tprintf("codegen: function aggregate parameter %d has unsupported ABI layout: %s", i, layout_msg)
				return
			}
			append(&param_layouts, layout)
			if !layout.memory {
				append(&param_scratch, bc_scratch_slot(&callee, layout.size, layout.align))
			} else {
				append(&param_scratch, bc.BC_INVALID_SCRATCH)
			}
		} else {
			append(&param_layouts, bc.BC_Aggregate_Layout{})
			append(&param_scratch, bc.BC_INVALID_SCRATCH)
		}
		callee.frame[BC_Binding_Key{rawptr(scope_canon(scope)), i}] = bc.BC_Value(len(params) - 1)
		callee.frame_slots[i] = bc.BC_Value(len(params) - 1)
		param_value := bc_fresh_value(&callee, mt)
		if is_aggregate {
			if aggregate_scope := bc_aggregate_scope(declared); aggregate_scope != nil {
				callee.aggregate_frames[BC_Binding_Key{rawptr(scope_canon(scope)), i}] = BC_Aggregate_Frame{param_value, aggregate_scope}
			}
		}
	}

	body, has_body := bc_handler_body(scope)
	result_layout: bc.BC_Aggregate_Layout
	has_result_layout := false
	sret_slot := bc.BC_INVALID_SCRATCH
	if has_body && body != nil && bc_declared_aggregate(body) {
		layout, layout_ok, layout_msg := bc_aggregate_abi_layout(body)
		if !layout_ok {
			l.prog.error = fmt.tprintf("codegen: function aggregate result has unsupported ABI layout: %s", layout_msg)
			return
		}
		result_layout, has_result_layout = layout, true
		if layout.memory do sret_slot = bc_scratch_slot(&callee, 8, 8)
	}
	if !has_body || body == nil {
		v := bc_fresh_value(&callee)
		bc_emit(&callee, bc.BC_Const{v, 0})
		body = nil
		bc_emit(&callee, bc.BC_Ret{v})
	} else {
		value := bc_lower_value(&callee, body)
		tmp.result_type = has_result_layout ? bc.Machine_Type.None : machine_type_of(body)
		if !has_result_layout && tmp.result_type == .None do tmp.result_type = tmp.value_types[int(value)]
		bc_emit(&callee, bc.BC_Ret{value})
	}

	for fn in l.registry.funcs {
		if fn.id == id {
			identity := fn.identity
			l.registry.funcs[int(id)] = bc.BC_Func {
				id = id,
				identity = identity,
				params = params[:],
				param_layouts = param_layouts[:],
				param_scratch = param_scratch[:],
				result = tmp.result_type,
				result_layout = result_layout,
				has_result_layout = has_result_layout,
				sret_slot = sret_slot,
				insts = tmp.insts[:],
				value_count = tmp.value_count,
				label_count = tmp.label_count,
				value_types = tmp.value_types[:],
				loops = tmp.loops[:],
				scratch = tmp.scratch[:],
			}
			break
		}
	}
}

// bc_lower_foreign_call lowers a call across the external frontier: each argument is
// lowered as an ordinary value, the (lib, symbol) pair is interned into the program's
// import list, and the call is emitted against that slot.
//
// The result's Machine_Type comes from the DECLARED production, which is the only
// thing known about an external's result — its value is not computable here.
bc_lower_foreign_call :: proc(l: ^BC_Lower, node: ^Type, v: Foreign_Call_Type) -> bc.BC_Value {
	args := make([]bc.BC_Value, len(v.args))
	arg_layouts := make([]bc.BC_Aggregate_Layout, len(v.args))
	cell_slots := make([]bc.BC_Scratch_Id, len(v.args))
	for i in 0 ..< len(cell_slots) do cell_slots[i] = bc.BC_INVALID_SCRATCH
	for a, i in v.args {
		constraint := i < len(v.arg_constraints) ? v.arg_constraints[i] : nil
		layout, has_layout := bc_declared_layout(constraint)
		writable := i < len(v.arg_writable) && v.arg_writable[i]
		if writable {
			if !has_layout do return bc_fail(l, fmt.tprintf("codegen: writable foreign argument %d of <%s>.%s has no static C layout", i, v.lib, v.symbol))
			if layout.size == 0 || layout.size > 0x7FFFFFFF {
				return bc_fail(l, fmt.tprintf("codegen: writable foreign argument %d of <%s>.%s has an unsupported layout size", i, v.lib, v.symbol))
			}
			if bc_declared_aggregate(constraint) {
				before := len(l.prog.scratch)
				args[i] = bc_lower_aggregate_argument(l, a, constraint, layout, false)
				if len(l.prog.scratch) <= before do return bc_fail(l, "codegen: writable aggregate did not materialize a cell")
				cell_slots[i] = bc.BC_Scratch_Id(len(l.prog.scratch) - 1)
				abi_layout, layout_ok, layout_msg := bc_aggregate_abi_layout(constraint)
				if !layout_ok do return bc_fail(l, fmt.tprintf("codegen: writable aggregate argument %d of <%s>.%s has unsupported ABI layout: %s", i, v.lib, v.symbol, layout_msg))
				abi_layout.indirect = true
				arg_layouts[i] = abi_layout
			} else {
				args[i], cell_slots[i] = bc_lower_scalar_cell(l, a, constraint, layout)
			}
		} else if has_layout && bc_declared_aggregate(constraint) {
			borrowed := i < len(v.arg_borrowed) && v.arg_borrowed[i]
			args[i] = bc_lower_aggregate_argument(l, a, constraint, layout, borrowed)
			abi_layout, layout_ok, layout_msg := bc_aggregate_abi_layout(constraint)
			if !layout_ok do return bc_fail(l, fmt.tprintf("codegen: aggregate argument %d of <%s>.%s has unsupported ABI layout: %s", i, v.lib, v.symbol, layout_msg))
			arg_layouts[i] = abi_layout
		} else {
			args[i] = bc_lower_value(l, a)
		}
		if l.prog.error != "" do return args[i]
		// An argument with no machine layout (a symbolic string, an unsized domain)
		// cannot be marshalled across the frontier.
		if int(args[i]) < len(l.prog.value_types) &&
		   l.prog.value_types[args[i]] == .None {
			return bc_fail(
				l,
				fmt.tprintf(
					"codegen: argument %d of <%s>.%s has no machine layout",
					i,
					v.lib,
					v.symbol,
				),
			)
		}
	}

	result_layout: bc.BC_Aggregate_Layout
	has_result_layout := false
	if bc_declared_aggregate(v.production) {
		layout, layout_ok, layout_msg := bc_aggregate_abi_layout(v.production)
		if !layout_ok do return bc_fail(l, fmt.tprintf("codegen: aggregate result from <%s>.%s has unsupported ABI layout: %s", v.lib, v.symbol, layout_msg))
		result_layout, has_result_layout = layout, true
	}
	mt := machine_type_of(v.production)
	// A `Str` result would have to be marshalled back from an address; only register
	// -sized results are handled so far.
	if !has_result_layout && mt == .Str {
		return bc_fail(
			l,
			fmt.tprintf("codegen: string results from <%s>.%s do not lower yet", v.lib, v.symbol),
		)
	}

	dst := bc_fresh_value(l, has_result_layout ? .U64 : mt)
	if has_result_layout {
		slot := bc_scratch_slot(l, result_layout.size, result_layout.align)
		bc_emit(l, bc.BC_Materialize{dst = dst, slot = slot, size = result_layout.size, borrowed = false})
	}
	slot := bc.bc_intern_import(l.registry, v.lib, v.symbol)
	bc_emit(l, bc.BC_Foreign_Call{dst = dst, slot = slot, args = args, arg_layouts = arg_layouts, result_layout = result_layout, has_result_layout = has_result_layout})

	// A writable formal is a cell, not the foreign function's scalar return.  The
	// call's nominal event is resumed only after the cell has been loaded back.
	result := dst
	for writeback in v.writebacks {
		i := writeback.argument
		if i < 0 || i >= len(args) || i >= len(cell_slots) || cell_slots[i] == bc.BC_INVALID_SCRATCH {
			return bc_fail(l, fmt.tprintf("codegen: writable foreign argument %d has no materialized cell", i))
		}
		constraint := i < len(v.arg_constraints) ? v.arg_constraints[i] : nil
		layout, has_layout := bc_declared_layout(constraint)
		if !has_layout do return bc_fail(l, fmt.tprintf("codegen: writeback for <%s>.%s has no static layout", v.lib, v.symbol))
		updated := args[i]
		aggregate := bc_declared_aggregate(constraint)
		if aggregate {
			updated_slot := bc_scratch_slot(l, layout.size, layout.align)
			updated = bc_fresh_value(l, .U64)
			bc_emit(l, bc.BC_Load_Aggregate{
				dst = updated,
				src_slot = cell_slots[i],
				dst_slot = updated_slot,
				size = layout.size,
			})
		} else {
			mt := machine_type_of(constraint)
			if mt == .None || bc.mtype_bits(mt) == 0 || layout.size > 8 {
				return bc_fail(l, fmt.tprintf("codegen: scalar writeback for <%s>.%s has an unsupported layout", v.lib, v.symbol))
			}
			updated = bc_fresh_value(l, mt)
			bc_emit(l, bc.BC_Load{
				dst = updated,
				slot = cell_slots[i],
				offset = 0,
				width = uint(layout.size * 8),
				signed = bc.mtype_signed(mt),
			})
		}
		if writeback.handler == nil {
			return bc_fail(l, fmt.tprintf("codegen: foreign resonant formal '%s' has no named event handler", writeback.formal_name))
		}
		if writeback.capture_index < 0 {
			return bc_fail(l, fmt.tprintf("codegen: foreign resonant formal '%s' requires a handler capture for writeback", writeback.formal_name))
		}
		payload := bc_lower_event_payload(l, writeback, updated, aggregate)
		if l.prog.error != "" do return payload
		result = bc_lower_named_handler(l, writeback.handler, writeback.capture_index, payload)
	}
	return result
}

// bc_const_int returns a node's value as an i64 when it is a concrete integer
// (foldable into an immediate), else ok=false.
bc_const_int :: proc(node: ^Type) -> (i64, bool) {
	if node == nil do return 0, false
	#partial switch v in node^ {
	case Integer_Type:
		if int_is_concrete(v) do return i64(int_value(v)), true
	}
	return 0, false
}

// bc_lower_compose lowers an arithmetic/comparison node, choosing the immediate
// mnemonic when an operand is a concrete integer. For non-commutative ops only the
// RIGHT operand may be the immediate; commutative ops normalize the constant there.
bc_lower_compose :: proc(l: ^BC_Lower, node: ^Type, v: Compose_Type) -> bc.BC_Value {
	op := op_to_bc(v.operator)
	mt := machine_type_of(node)
	cmp := bc.bc_op_is_comparison(op)

	lk, l_const := bc_const_int(v.left)
	rk, r_const := bc_const_int(v.right)

	// Float operands never fold to an integer immediate — keep them register form.
	is_float := bc.mtype_is_float(mt)
	if is_float {l_const = false;r_const = false}

	commutative :=
		op == .Add ||
		op == .Multiply ||
		op == .BitAnd ||
		op == .BitOr ||
		op == .BitXor ||
		op == .Equal ||
		op == .NotEqual

	// a op #rk — always valid (immediate is the right side).
	if r_const && !l_const {
		a := bc_lower_value(l, v.left)
		return bc_emit_imm(l, node, op, a, rk, cmp, mt)
	}
	// #lk op b  ==  b op #lk on a commutative op.
	if l_const && !r_const && commutative {
		b := bc_lower_value(l, v.right)
		return bc_emit_imm(l, node, op, b, lk, cmp, mt)
	}

	// General register/register form.
	a := bc_lower_value(l, v.left)
	b := bc_lower_value(l, v.right)
	if mt == .None do mt = bc.mtype_wider(l.prog.value_types[a], l.prog.value_types[b])
	if cmp {
		dst := bc_fresh_value(l, .U8)
		bc_emit(l, bc.BC_Cmp{dst, op, a, b})
		return dst
	}
	dst := bc_fresh_value(l, mt)
	bc_emit(l, bc.BC_Bin{dst, op, a, b})
	return dst
}

bc_emit_imm :: proc(
	l: ^BC_Lower,
	node: ^Type,
	op: bc.BC_Op,
	a: bc.BC_Value,
	imm: i64,
	cmp: bool,
	mt_in: bc.Machine_Type,
) -> bc.BC_Value {
	mt := mt_in
	if mt == .None do mt = l.prog.value_types[a]
	if cmp {
		dst := bc_fresh_value(l, .U8)
		bc_emit(l, bc.BC_Cmp_Imm{dst, op, a, imm})
		return dst
	}
	dst := bc_fresh_value(l, mt)
	bc_emit(l, bc.BC_Bin_Imm{dst, op, a, imm})
	return dst
}

// A ??N fixed point → ONE Load_Arg{slot, width, signed}; the Load_Arg alone carries
// the domain (??::u8 normalized by the backend's movzx/movsx, no separate mask).
// fixedpoint_id gives the stable, appearance-ordered index = the argv position.
bc_lower_fixed_point :: proc(l: ^BC_Lower, node: ^Type) -> bc.BC_Value {
	slot := fixedpoint_id(node)
	mt := machine_type_of(node)

	if bc.mtype_is_float(mt) {
		dst := bc_fresh_value(l, mt)
		bc_emit(l, bc.BC_Load_Arg{dst, slot, bc.mtype_bits(mt), true})
		return dst
	}

	width, signed := bc_unknown_domain(node)
	dst := bc_fresh_value(l, mt == .None ? .I64 : mt)
	bc_emit(l, bc.BC_Load_Arg{dst, slot, width, signed})
	return dst
}

// bc_lower_string_const lays a concrete string into .rodata and emits a pointer.
bc_lower_string_const :: proc(l: ^BC_Lower, s: string) -> bc.BC_Value {
	id := len(l.registry.rodata)
	append(&l.registry.rodata, s)
	dst := bc_fresh_value(l, .Str)
	bc_emit(l, bc.BC_Str_Const{dst, s, id})
	return dst
}

bc_declared_layout :: proc(constraint: ^Type) -> (C_Layout, bool) {
	if constraint == nil do return {}, false
	seen := make(map[rawptr]bool)
	defer delete(seen)
	return c_layout_type(fold_constraint(constraint), &seen)
}

bc_declared_aggregate :: proc(constraint: ^Type) -> bool {
	if constraint == nil do return false
	cur := follow(constraint)
	if cur == nil do return false
	#partial switch v in cur^ {
	case Scope_Type:
		for k in v.kind do if k != .Product && k != .Expand do return true
	}
	return false
}

// bc_aggregate_abi_layout turns the current fixed C layout into the neutral
// pieces consumed by a backend ABI.  The fixed-layout language has no flexible
// members, vectors, or unaligned address-bearing fields, so a supported small
// aggregate is completely described by at most two eightbyte pieces.
bc_aggregate_abi_layout :: proc(constraint: ^Type) -> (bc.BC_Aggregate_Layout, bool, string) {
	if !bc_declared_aggregate(constraint) do return {}, false, "not an aggregate"
	layout, ok := bc_declared_layout(constraint)
	if !ok do return {}, false, "aggregate has no fixed C layout"
	if layout.size <= 0 do return {}, false, "aggregate has an empty C layout"
	if layout.align > 8 do return {}, false, "aggregate alignment above 8 bytes is unsupported"
	result := bc.BC_Aggregate_Layout{size = layout.size, align = layout.align, memory = layout.size > 16}
	if result.memory do return result, true, ""

	scope := bc_aggregate_scope(fold_constraint(constraint))
	if scope == nil do return {}, false, "aggregate has no structural scope"
	declared := scope
	pieces := make([dynamic]bc.BC_Aggregate_Piece)
	chunk_end := [2]int{0, 0}
	chunk_class := [2]bc.Machine_Type{.None, .None}
	for i in 0 ..< len(declared.kind) {
		if declared.kind[i] == .Product || declared.kind[i] == .Expand do continue
		field_no := 0
		for j in 0 ..< i {
			if declared.kind[j] != .Product && declared.kind[j] != .Expand do field_no += 1
		}
		if field_no >= len(layout.fields) do return {}, false, "aggregate field layout is inconsistent"
		field := layout.fields[field_no]
		field_constraint := i < len(declared.constraints) ? declared.constraints[i] : nil
		if field.indirect {
			// This is the existing borrowed-indirect representation.  It is an
			// INTEGER word in a C layout, never a source-level pointer value.
			field_constraint = nil
		}
		if field.size <= 0 || field.offset < 0 || field.offset + field.size > 16 {
			return {}, false, "aggregate field is outside the supported 16-byte layout"
		}
		first := field.offset / 8
		last := (field.offset + field.size - 1) / 8
		if first != last do return {}, false, "aggregate field crosses an eightbyte boundary"
		mt := bc.Machine_Type.U64
		if !field.indirect {
			if bc_declared_aggregate(field_constraint) {
				child, child_ok, child_msg := bc_aggregate_abi_layout(field_constraint)
				if !child_ok do return {}, false, child_msg
				if child.memory do return {}, false, "nested MEMORY aggregate in a small aggregate is unsupported"
				// The parent C layout already accounts for the nested field's
				// offset.  Its ABI class is merged below from the child pieces.
				for child_piece in child.pieces {
					absolute := field.offset + child_piece.offset
					if absolute / 8 != (absolute + child_piece.size - 1) / 8 {
						return {}, false, "nested aggregate piece crosses an eightbyte boundary"
					}
					chunk := absolute / 8
					if child_piece.machine == .F32 || child_piece.machine == .F64 {
						if chunk_class[chunk] == .None do chunk_class[chunk] = child_piece.machine
					} else {
						chunk_class[chunk] = .U64
					}
					chunk_end[chunk] = max(chunk_end[chunk], absolute + child_piece.size)
				}
				continue
			}
			mt = machine_type_of(field_constraint)
			if mt == .Str || mt == .None || bc.mtype_bits(mt) == 0 {
				return {}, false, "aggregate field has no supported integer or SSE machine layout"
			}
		}
		chunk := first
		if bc.mtype_is_float(mt) {
			if chunk_class[chunk] == .None do chunk_class[chunk] = mt
		} else {
			chunk_class[chunk] = .U64
		}
		chunk_end[chunk] = max(chunk_end[chunk], field.offset + field.size)
	}
	for chunk in 0 ..< 2 {
		if chunk_end[chunk] == 0 do continue
		mt := chunk_class[chunk]
		if mt == .None do return {}, false, "aggregate has an unclassified eightbyte"
		if mt == .F32 && chunk_end[chunk] > (chunk * 8 + 4) do mt = .F64
		append(&pieces, bc.BC_Aggregate_Piece{offset = chunk * 8, size = chunk_end[chunk] - chunk * 8, machine = mt})
	}
	if len(pieces) == 0 do return {}, false, "aggregate has no supported ABI pieces"
	result.pieces = pieces[:]
	return result, true, ""
}

bc_scratch_slot :: proc(l: ^BC_Lower, size, align: int) -> bc.BC_Scratch_Id {
	id := bc.BC_Scratch_Id(len(l.prog.scratch))
	append(&l.prog.scratch, bc.BC_Scratch_Slot{id = id, size = size, align = align})
	return id
}

bc_aggregate_scope :: proc(value: ^Type) -> ^Scope_Type {
	cur := follow(value)
	if cur == nil do return nil
	#partial switch &v in cur^ {
	case Scope_Type:
		return &v
	case Carve_Type:
		if sub := fold_carve_type(value); sub != nil {
			return sub
		}
	}
	return nil
}

bc_lower_aggregate_argument :: proc(
	l: ^BC_Lower,
	value: ^Type,
	constraint: ^Type,
	layout: C_Layout,
	borrowed: bool,
) -> bc.BC_Value {
	scope := bc_aggregate_scope(value)
	declared := bc_aggregate_scope(fold_constraint(constraint))
	if scope == nil || declared == nil {
		if value != nil {
			_, is_foreign := value^.(Foreign_Call_Type)
			_, is_execute := value^.(Execute_Type)
			_, is_carve := value^.(Carve_Type)
			if is_foreign || is_execute || is_carve {
			// An aggregate result already owns a stable scratch home.  Passing that
			// home onward avoids copying it into a transient pseudo-value.
			return bc_lower_value(l, value)
			}
		}
		return bc_fail(l, "codegen: aggregate argument has no structural value")
	}

	slot := bc_scratch_slot(l, layout.size, layout.align)
	stores := make([dynamic]bc.BC_Materialize_Store)
	inputs := make([dynamic]bc.BC_Value)
	field_no := 0
	for i in 0 ..< len(scope.kind) {
		if scope.kind[i] == .Product || scope.kind[i] == .Expand do continue
		if field_no >= len(layout.fields) do return bc_fail(l, "codegen: aggregate field layout is inconsistent")
		field := layout.fields[field_no]
		field_no += 1
		field_constraint := i < len(declared.constraints) ? declared.constraints[i] : nil
		field_value := reduce_slot_value(scope, i)
		if field_value == nil do return bc_fail(l, "codegen: aggregate field has no value")

		if field.indirect {
			child_layout, child_ok := bc_declared_layout(field_constraint)
			if !child_ok || !bc_declared_aggregate(field_constraint) {
				return bc_fail(l, "codegen: borrowed indirect field is not an aggregate")
			}
			child := bc_lower_aggregate_argument(l, field_value, field_constraint, child_layout, true)
			append(&stores, bc.BC_Materialize_Store{field.offset, child, 8, false})
			append(&inputs, child)
			continue
		}

		if bc_declared_aggregate(field_constraint) {
			child_layout, child_ok := bc_declared_layout(field_constraint)
			if !child_ok do return bc_fail(l, "codegen: nested aggregate has no C layout")
			child := bc_lower_aggregate_argument(l, field_value, field_constraint, child_layout, false)
			append(&stores, bc.BC_Materialize_Store{field.offset, child, child_layout.size, true})
			append(&inputs, child)
			continue
		}

		scalar := bc_lower_value(l, field_value)
		if l.prog.error != "" do return scalar
		append(&stores, bc.BC_Materialize_Store{field.offset, scalar, field.size, false})
		append(&inputs, scalar)
	}

	dst := bc_fresh_value(l, .U64)
	bc_emit(l, bc.BC_Materialize{dst = dst, slot = slot, size = layout.size, borrowed = borrowed, stores = stores[:], inputs = inputs[:]})
	return dst
}

bc_lower_scalar_cell :: proc(
	l: ^BC_Lower,
	value: ^Type,
	constraint: ^Type,
	layout: C_Layout,
) -> (bc.BC_Value, bc.BC_Scratch_Id) {
	if layout.size <= 0 || layout.size > 8 {
		return bc_fail(l, "codegen: writable scalar has no supported cell width"), bc.BC_INVALID_SCRATCH
	}
	slot := bc_scratch_slot(l, layout.size, layout.align)
	scalar := bc_lower_value(l, value)
	if l.prog.error != "" do return scalar, bc.BC_INVALID_SCRATCH
	dst := bc_fresh_value(l, .U64)
	stores := make([dynamic]bc.BC_Materialize_Store, 1)
	inputs := make([dynamic]bc.BC_Value, 1)
	stores[0] = bc.BC_Materialize_Store{offset = 0, value = scalar, size = layout.size}
	inputs[0] = scalar
	bc_emit(l, bc.BC_Materialize{dst = dst, slot = slot, size = layout.size, borrowed = false, stores = stores[:], inputs = inputs[:]})
	return dst, slot
}

// bc_lower_event_payload builds the nominal event value that the existing named
// handler receives. The changed formal supplies one field; all other fields are
// ordinary declared defaults. This is a continuation value, not a Scope_Type
// mutation, and therefore remains valid across a foreign call.
bc_lower_event_payload :: proc(
	l: ^BC_Lower,
	writeback: Foreign_Writeback,
	updated: bc.BC_Value,
	updated_aggregate: bool,
) -> bc.BC_Value {
	event := writeback.event
	if event == nil do return bc_fail(l, "codegen: resonant foreign formal has no nominal event identity")
	field_scope, field_index := scope_resolve(event, writeback.formal_name, -1, true)
	if field_scope == nil || scope_canon(field_scope) != scope_canon(event) || field_index < 0 {
		return bc_fail(l, fmt.tprintf("codegen: event '%s' has no field for resonant formal '%s'", bc_source_identity(new_type(event^)), writeback.formal_name))
	}
	layout, ok := c_layout(event)
	if !ok do return bc_fail(l, "codegen: resonant event has no statically known aggregate layout")
	field_no := 0
	changed: C_Field_Layout
	for i in 0 ..< len(event.kind) {
		if event.kind[i] == .Product || event.kind[i] == .Expand do continue
		if i == field_index {
			if field_no >= len(layout.fields) do return bc_fail(l, "codegen: resonant event field layout is inconsistent")
			changed = layout.fields[field_no]
			break
		}
		field_no += 1
	}
	if field_no >= len(layout.fields) do return bc_fail(l, "codegen: resonant event field is not materializable")

	slot := bc_scratch_slot(l, layout.size, layout.align)
	stores := make([dynamic]bc.BC_Materialize_Store)
	inputs := make([dynamic]bc.BC_Value)
	field_no = 0
	for i in 0 ..< len(event.kind) {
		if event.kind[i] == .Product || event.kind[i] == .Expand do continue
		field := layout.fields[field_no]
		field_no += 1
		if i == field_index {
			if updated_aggregate {
				if !changed.indirect && changed.size > 0 {
					append(&stores, bc.BC_Materialize_Store{offset = field.offset, value = updated, size = changed.size, copy_bytes = true})
					append(&inputs, updated)
					continue
				}
				return bc_fail(l, "codegen: aggregate resonant event field is not copyable")
			}
			if field.indirect || field.size > 8 do return bc_fail(l, "codegen: scalar resonant event field is not loadable")
			append(&stores, bc.BC_Materialize_Store{offset = field.offset, value = updated, size = field.size})
			append(&inputs, updated)
			continue
		}
		field_constraint := i < len(event.constraints) ? event.constraints[i] : nil
		if field.indirect || field_constraint == nil do return bc_fail(l, "codegen: resonant event has an unsupported borrowed or untyped field")
		if bc_declared_aggregate(field_constraint) {
			child_layout, child_ok := bc_declared_layout(field_constraint)
			if !child_ok do return bc_fail(l, "codegen: resonant event nested field has no static layout")
			child := bc_lower_aggregate_argument(l, reduce_slot_value(event, i), field_constraint, child_layout, false)
			append(&stores, bc.BC_Materialize_Store{offset = field.offset, value = child, size = child_layout.size, copy_bytes = true})
			append(&inputs, child)
		} else {
			value := bc_lower_value(l, reduce_slot_value(event, i))
			if l.prog.error != "" do return value
			append(&stores, bc.BC_Materialize_Store{offset = field.offset, value = value, size = field.size})
			append(&inputs, value)
		}
	}
	dst := bc_fresh_value(l, .U64)
	bc_emit(l, bc.BC_Materialize{dst = dst, slot = slot, size = layout.size, borrowed = false, stores = stores[:], inputs = inputs[:]})
	return dst
}

// Lower a nominal handler as a named internal function. Its capture is passed as
// the continuation payload; aggregate captures use the same abstract address ABI
// as foreign aggregates and are decoded by BC_Load_Indirect in the callee.
bc_lower_named_handler :: proc(
	l: ^BC_Lower,
	handler: ^Type,
	capture_index: int,
	payload: bc.BC_Value,
) -> bc.BC_Value {
	scope := event_handler_scope(handler)
	if scope == nil do return bc_fail(l, "codegen: named event handler has no scope")
	key := rawptr(scope_canon(scope))
	id, found := l.functions[key]
	if !found {
		id = bc.Func_Id(len(l.registry.funcs))
		l.functions[key] = id
		append(&l.registry.funcs, bc.BC_Func{id = id, identity = bc_source_identity(handler)})
	}
	if !l.function_done[key] {
		l.function_done[key] = true
		bc_lower_internal_function(l, scope, id)
	}

	args := make([dynamic]bc.BC_Value)
	arg_layouts := make([dynamic]bc.BC_Aggregate_Layout)
	param_index := 0
	for i in 0 ..< len(scope.kind) {
		if scope.kind[i] == .Product || scope.kind[i] == .Resonance_Pull do continue
		if i == capture_index {
			append(&args, payload)
		} else {
			append(&args, bc_lower_value(l, reduce_slot_value(scope, i)))
		}
		// Use the callee's published parameter plan, not a second inference from
		// the handler surface.  Captured event payloads intentionally have a
		// different nominal shape from the handler's source constraint.
		if int(id) < len(l.registry.funcs) && param_index < len(l.registry.funcs[int(id)].param_layouts) {
			append(&arg_layouts, l.registry.funcs[int(id)].param_layouts[param_index])
		} else {
			append(&arg_layouts, bc.BC_Aggregate_Layout{})
		}
		param_index += 1
	}
	result_type := bc_function_result_type(scope)
	result_layout: bc.BC_Aggregate_Layout
	has_result_layout := false
	if body, body_ok := bc_handler_body(scope); body_ok && bc_declared_aggregate(body) {
		layout, layout_ok, layout_msg := bc_aggregate_abi_layout(body)
		if !layout_ok do return bc_fail(l, fmt.tprintf("codegen: handler aggregate result has unsupported ABI layout: %s", layout_msg))
		result_layout, has_result_layout = layout, true
	}
	dst := bc_fresh_value(l, result_type)
	if has_result_layout {
		slot := bc_scratch_slot(l, result_layout.size, result_layout.align)
		bc_emit(l, bc.BC_Materialize{dst = dst, slot = slot, size = result_layout.size, borrowed = false})
	}
	bc_emit(l, bc.BC_Call{dst = dst, func = id, args = args[:], arg_layouts = arg_layouts[:], result_layout = result_layout, has_result_layout = has_result_layout})
	return dst
}

// bc_unknown_domain reads a ??'s declared domain width/signedness from the
// Cast_Type that pins it (??::u8 → {8,false}). A bare Unknown is unsized.
bc_unknown_domain :: proc(node: ^Type) -> (width: uint, signed: bool) {
	if node == nil do return 0, false
	#partial switch v in node^ {
	case Cast_Type:
		if tgt, ok := cast_target(v.target); ok {
			if tgt.kind == .Integer do return tgt.width, tgt.signed
			if tgt.kind == .Bool do return 8, false
		}
	}
	return 0, false
}

// A pattern whose target survives as a fixed point becomes a branch chain: test
// each branch's match against the target, jump to the firing product.
bc_lower_pattern :: proc(l: ^BC_Lower, p: Pattern_Type) -> bc.BC_Value {
	for branch in p.branches {
		if _, ok := bc_recursive_tail_carve(branch.product, l.current_scope); ok {
			return bc_lower_recursive_pattern(l, p, bc_pattern_home_scope(p.target))
		}
	}
	return bc_lower_pattern_linear(l, p)
}

bc_lower_pattern_linear :: proc(l: ^BC_Lower, p: Pattern_Type) -> bc.BC_Value {
	target := bc_lower_value(l, p.target)
	end := bc_fresh_label(l)
	// Merge slot: every branch writes its product here via BC_Move (a phi).
	rt := len(p.branches) > 0 ? machine_type_of(p.branches[0].product) : bc.Machine_Type.I64
	if rt == .None do rt = .I64
	result := bc_fresh_value(l, rt)

	for branch in p.branches {
		// A bool value-match (`=true`/`=false`): fire when target equals the bool.
		if bval, is_bool := bc_branch_bool_value(branch); is_bool {
			next := bc_fresh_label(l)
			want := bc_fresh_value(l);bc_emit(l, bc.BC_Const{want, bval ? 1 : 0})
			eq := bc_fresh_value(l, .U8);bc_emit(l, bc.BC_Cmp{eq, .Equal, target, want})
			bc_emit(l, bc.BC_Branch_Zero{eq, next}) // target != bval → skip this branch
			prod := bc_lower_value(l, branch.product)
			bc_emit(l, bc.BC_Move{result, prod})
			bc_emit(l, bc.BC_Jump{end})
			bc_emit(l, bc.BC_Label_Def{next})
			continue
		}
		lo, hi, ok := bc_branch_int_range(branch)
		if !ok {
			prod := bc_lower_value(l, branch.product)
			bc_emit(l, bc.BC_Move{result, prod})
			bc_emit(l, bc.BC_Jump{end})
			continue
		}
		next := bc_fresh_label(l)
		if lo_v, has_lo := lo.?; has_lo {
			lo_reg := bc_fresh_value(l);bc_emit(l, bc.BC_Const{lo_reg, lo_v})
			ge_lo := bc_fresh_value(l, .U8);bc_emit(l, bc.BC_Cmp{ge_lo, .GreaterEqual, target, lo_reg})
			bc_emit(l, bc.BC_Branch_Zero{ge_lo, next})
		}
		if hi_v, has_hi := hi.?; has_hi {
			hi_reg := bc_fresh_value(l);bc_emit(l, bc.BC_Const{hi_reg, hi_v})
			le_hi := bc_fresh_value(l, .U8);bc_emit(l, bc.BC_Cmp{le_hi, .LessEqual, target, hi_reg})
			bc_emit(l, bc.BC_Branch_Zero{le_hi, next})
		}
		prod := bc_lower_value(l, branch.product)
		bc_emit(l, bc.BC_Move{result, prod})
		bc_emit(l, bc.BC_Jump{end})
		bc_emit(l, bc.BC_Label_Def{next})
	}
	bc_emit(l, bc.BC_Label_Def{end})
	return result
}

BC_Recursive_Site :: struct {
	index: int,
	state: bc.BC_Value,
}

// This recognizes only a pure recursive tail. Arithmetic around the recursive
// collapse remains a non-tail residual and keeps the existing rejection.
bc_recursive_tail_carve :: proc(product: ^Type, current: ^Scope_Type) -> (^Carve_Type, bool) {
	if product == nil do return nil, false
	if ex, ok := product^.(Execute_Type); ok {
		cur := follow(ex.target)
		if cur != nil {
			if cv, is_carve := &cur^.(Carve_Type); is_carve {
				callee := collapse_source(cv.source)
				if current != nil && callee != nil && scope_canon(current) == scope_canon(callee) {
					return cv, true
				}
			}
		}
	}
	return nil, false
}

bc_pattern_home_scope :: proc(target: ^Type) -> ^Scope_Type {
	if target == nil do return nil
	#partial switch v in target^ {
	case Mention_Type:
		return v.match_scope
	case Reference_Type:
		if v.reference != nil do return v.reference.match_scope
	}
	return nil
}

// A terminal recursive pattern is represented as a loop over its carved binding
// values. The loop-carried values are bytecode phi destinations; no address or
// pointer value is introduced into the language or bytecode.
bc_lower_recursive_pattern :: proc(l: ^BC_Lower, p: Pattern_Type, given_home: ^Scope_Type) -> bc.BC_Value {
	home := given_home != nil ? given_home : l.current_scope
	if home == nil do return bc_fail(l, "codegen: recursive pattern has no enclosing scope")
	old_frame := l.frame
	old_slots := l.frame_slots
	l.frame = make(map[BC_Binding_Key]bc.BC_Value)
	l.frame_slots = make(map[int]bc.BC_Value)
	for key, value in old_frame do l.frame[key] = value
	for key, value in old_slots do l.frame_slots[key] = value
	defer {
		delete(l.frame)
		delete(l.frame_slots)
		l.frame = old_frame
		l.frame_slots = old_slots
	}

	target := bc_lower_value(l, p.target)
	if key, ok := bc_binding_key(p.target); ok do l.frame[key] = target
	if key, ok := bc_binding_key(p.target); ok do l.frame_slots[key.index] = target

	sites: [dynamic]BC_Recursive_Site
	defer delete(sites)
	for branch in p.branches {
		carve, is_tail := bc_recursive_tail_carve(branch.product, l.current_scope)
		if !is_tail do continue
		for ref in carve.references {
			idx := carve_ref_index(ref, home)
			if idx < 0 do continue
			seen := false
			for site in sites do if site.index == idx do seen = true
			if seen do continue
			key := BC_Binding_Key{rawptr(scope_canon(home)), idx}
			state: bc.BC_Value
			if value, found := l.frame[key]; found {
				state = value
			} else if value, found := l.frame_slots[idx]; found {
				state = value
			} else {
				state = bc_lower_value(l, reduce_slot_value(home, idx))
				l.frame[key] = state
				l.frame_slots[idx] = state
			}
			append(&sites, BC_Recursive_Site{idx, state})
		}
	}
	if len(sites) == 0 do return bc_fail(l, "codegen: recursive tail has no carried bindings")

	rt := len(p.branches) > 0 ? machine_type_of(p.branches[0].product) : bc.Machine_Type.I64
	if rt == .None do rt = .I64
	result := bc_fresh_value(l, rt)
	header := bc_fresh_label(l)
	latch := bc_fresh_label(l)
	end := bc_fresh_label(l)
	bc_emit(l, bc.BC_Label_Def{header})
	latch_emitted := false

	for branch in p.branches {
		carve, is_tail := bc_recursive_tail_carve(branch.product, l.current_scope)
		if bval, is_bool := bc_branch_bool_value(branch); is_bool {
			next := bc_fresh_label(l)
			want := bc_fresh_value(l); bc_emit(l, bc.BC_Const{want, bval ? 1 : 0})
			eq := bc_fresh_value(l, .U8); bc_emit(l, bc.BC_Cmp{eq, .Equal, target, want})
			bc_emit(l, bc.BC_Branch_Zero{eq, next})
			if is_tail {
				if !latch_emitted {bc_emit(l, bc.BC_Label_Def{latch}); latch_emitted = true}
				bc_lower_recursive_update(l, carve, home, sites[:])
				bc_emit(l, bc.BC_Jump{header})
			} else {
				prod := bc_lower_value(l, branch.product)
				bc_emit(l, bc.BC_Move{result, prod}); bc_emit(l, bc.BC_Jump{end})
			}
			bc_emit(l, bc.BC_Label_Def{next})
			continue
		}
		lo, hi, range_ok := bc_branch_int_range(branch)
		if range_ok {
			next := bc_fresh_label(l)
			if lo_v, has := lo.?; has {
				lo_reg := bc_fresh_value(l); bc_emit(l, bc.BC_Const{lo_reg, lo_v})
				ge := bc_fresh_value(l, .U8); bc_emit(l, bc.BC_Cmp{ge, .GreaterEqual, target, lo_reg})
				bc_emit(l, bc.BC_Branch_Zero{ge, next})
			}
			if hi_v, has := hi.?; has {
				hi_reg := bc_fresh_value(l); bc_emit(l, bc.BC_Const{hi_reg, hi_v})
				le := bc_fresh_value(l, .U8); bc_emit(l, bc.BC_Cmp{le, .LessEqual, target, hi_reg})
				bc_emit(l, bc.BC_Branch_Zero{le, next})
			}
			if is_tail {
				if !latch_emitted {bc_emit(l, bc.BC_Label_Def{latch}); latch_emitted = true}
				bc_lower_recursive_update(l, carve, home, sites[:])
				bc_emit(l, bc.BC_Jump{header})
			} else {
				prod := bc_lower_value(l, branch.product)
				bc_emit(l, bc.BC_Move{result, prod}); bc_emit(l, bc.BC_Jump{end})
			}
			bc_emit(l, bc.BC_Label_Def{next})
			continue
		}
		if is_tail {
			if !latch_emitted {bc_emit(l, bc.BC_Label_Def{latch}); latch_emitted = true}
			bc_lower_recursive_update(l, carve, home, sites[:])
			bc_emit(l, bc.BC_Jump{header})
		} else {
			prod := bc_lower_value(l, branch.product)
			bc_emit(l, bc.BC_Move{result, prod}); bc_emit(l, bc.BC_Jump{end})
		}
	}
	bc_emit(l, bc.BC_Label_Def{end})
	exits := make([dynamic]bc.BC_Label, 1)
	exits[0] = end
	append(&l.prog.loops, bc.Loop_Info{header = header, latch = latch, exits = exits[:]})
	return result
}

bc_lower_recursive_update :: proc(l: ^BC_Lower, carve: ^Carve_Type, home: ^Scope_Type, sites: []BC_Recursive_Site) {
	for site in sites {
		for ref, i in carve.references {
			if carve_ref_index(ref, home) != site.index do continue
			if i >= len(carve.types) do continue
			next := bc_lower_value(l, carve.types[i])
			bc_emit(l, bc.BC_Move{dst = site.state, src = next})
			break
		}
	}
}

// Extract a concrete bool from a value-match branch. Only a singleton Bool_Type
// qualifies — a full `{true,false}` is not a test. A value-match branch (`=v`) is a
// producer scope `{-> v}`; read through its single production to the reified value.
bc_branch_bool_value :: proc(branch: Pattern_Branch) -> (val: bool, ok: bool) {
	if branch.match == nil do return false, false
	folded := fold_type(branch.match)
	if folded == nil do folded = branch.match
	scope, is_scope := folded^.(Scope_Type)
	if !is_scope do return false, false
	prods := scope_productions(scope)
	if len(prods) != 1 || prods[0] == nil do return false, false
	inner := fold_type(prods[0])
	if inner == nil do inner = prods[0]
	#partial switch b in inner^ {
	case Bool_Type:
		if v, has := b.value.?; has do return v, true
	}
	return false, false
}

// Extract a concrete integer interval from a pattern branch, if it is one.
// Either bound may be absent; an interval with neither bound is the legitimate
// unconstrained/default branch and is lowered without a guard.
bc_branch_int_range :: proc(branch: Pattern_Branch) -> (lo: Maybe(i64), hi: Maybe(i64), ok: bool) {
	if branch.match == nil do return nil, nil, false
	if it, ok := fold_type_intervals(branch.match).?; ok {
		ints := it.integer_intervals
		if len(ints) == 1 {
			lo: Maybe(i64)
			hi: Maybe(i64)
			if value, has := ints[0].lo.?; has do lo = i64(value)
			if value, has := ints[0].hi.?; has do hi = i64(value)
			return lo, hi, true
		}
	}
	return nil, nil, false
}

// bc_compose_is_string reports whether an arithmetic node operates on strings.
bc_compose_is_string :: proc(node: ^Type) -> bool {
	if node == nil do return false
	#partial switch v in node^ {
	case Compose_Type:
		return bc_operand_is_string(v.left) || bc_operand_is_string(v.right)
	}
	return false
}

bc_operand_is_string :: proc(node: ^Type) -> bool {
	if node == nil do return false
	#partial switch v in node^ {
	case String_Type:
		return true
	case Compose_Type:
		return bc_compose_is_string(node)
	case Cast_Type:
		if tgt, ok := cast_target(v.target); ok do return tgt.kind == .String
	}
	if env := fold_type(node); env != nil {
		#partial switch e in env^ {
		case String_Type:
			return true
		}
	}
	return false
}
