(* Oz.Wasm: A fast Delphi WebAssembly interpreter
 * Copyright (c) 2021 Tomsk, Marat Shaimardanov
 * SPDX-License-Identifier: (GPL-3.0-or-later OR Apache-2.0)
 *)
unit Oz.Wasm.Interpreter;

interface

uses
  System.SysUtils, System.Math, Oz.Wasm.Utils, Oz.Wasm.Limits, Oz.Wasm.Module,
  Oz.Wasm.Value, Oz.Wasm.Types, Oz.Wasm.Instruction;

{$T+}
{$SCOPEDENUMS ON}

type

{$Region 'TExecutionResult: The result of an execution'}

  TExecutionResult = record
    // This is true if the execution has trapped.
    trapped: Boolean;
    // This is true if value contains valid data.
    has_value: Boolean;
    // The result value. Valid if `has_value = true`.
    value: TValue;
    // Constructs result with a value.
    constructor From(const value: TValue); overload;
    // Constructs result in "void" or "trap" state depending on the success flag.
    // Prefer using Void and Trap constants instead.
    constructor From(success: Boolean); overload;
  end;
const
  BranchImmediateSize = 2 * sizeof(uint32);
  // Shortcut for execution that resulted in successful execution,
  // but without a result.
  Void: TExecutionResult = (has_value: False);
  // Shortcut for execution that resulted in a trap.
  Trap: TExecutionResult = (trapped: True);

{$EndRegion}

{$Region 'TExecutionContext: execution context'}

type
  // The storage for information shared by calls in the same execution "thread".
  // Users may decide how to allocate the execution context,
  // but some good defaults are available.
  TExecutionContext = class
  type
    // Call depth increment guard.
    // It will automatically decrement the call depth to the original value
    // when going out of scope.
    TGuard = class
      // Reference to the guarded execution context.
      m_execution_context: TExecutionContext;
      constructor Create(ctx: TExecutionContext);
      destructor Destroy; override;
    end;
  var
    depth: Integer;  // Current call depth.
  public
    // Increments the call depth and returns the guard object which decrements
    // the call depth back to the original value when going out of scope.
    function increment_call_depth: TGuard;
  end;

{$EndRegion}

{$Region 'TTableElement: Table element, which references a function in any instance'}

  PInstance = ^TInstance;
  TTableElement = record
    // Pointer to function's instance or nullptr when table element is not initialized.
    instance: PInstance;
    // Index of the function in instance.
    func_idx: TFuncIdx;
    // This pointer is empty most of the time and is used only to keep instance alive
    // in one edge case, when start function traps, but instantiate has already
    // modified some elements of a shared (imported) table.
    shared_instance: PInstance;
  end;

  table_elements = TArray<TTableElement>;
  table_ptr = ^table_elements;

{$EndRegion}

{$Region 'ExecuteFunction: WebAssembly or host function execution'}

  THostFunctionPtr = function(host_context: TObject; Instance: Pointer;
    const args: PValue; var ctx: TExecutionContext): TExecutionResult;

  TExecuteFunction = class
  private
    // Pointer to WebAssembly function instance.
    // Equals nullptr in case this ExecuteFunction represents host function.
    m_instance: PInstance;
    // Index of WebAssembly function.
    // Equals 0 in case this ExecuteFunction represents host function.
    m_func_idx: TFuncIdx;
    // Pointer to a host function.
    // Equals nullptr in case this ExecuteFunction represents WebAssembly function.
    m_host_function: THostFunctionPtr;
    // Opaque context of host function execution,
    // which is passed to it as host_context parameter.
    // Doesn't have value in case this ExecuteFunction represents WebAssembly function.
    m_host_context: TObject;
  public
    constructor Create(instance: PInstance; func_idx: TFuncIdx); overload;
    // Host function constructor without context.
    // The function will always be called with empty host_context argument.
    constructor Create(f: THostFunctionPtr); overload;
    // Host function constructor with context.
    // The function will be called with a reference to @a host_context.
    // Copies of the function will have their own copy of @a host_context.
    constructor Create(f: THostFunctionPtr; host_context: TObject); overload;
    // Function call operator.
    function Call(instance: PInstance; const args: PValue;
      var ctx: TExecutionContext): TExecutionResult;
    // Function pointer stored inside this object.
    function GetHostFunction: THostFunctionPtr;
  end;

{$EndRegion}

{$Region 'TExternalFunction: imported and exported functions'}

  TExternalFunction = record
  var
    func: TExecuteFunction;
    input_types: TSpan<TValType>;
    output_types: TSpan<TValType>;
  public
    constructor From(const func: TExecuteFunction; const input_types: TSpan<TValType>;
      const output_types: TSpan<TValType>); overload;
    constructor From(const func: TExecuteFunction; const typ: TFuncType); overload;
  end;

{$EndRegion}

{$Region 'TExternalGlobal'}

  TExternalGlobal = record
    value: TValue;
    typ: TGlobalType;
  end;

{$EndRegion}

{$Region 'TInstance: The module instance'}

  TInstance = record
  var
    // Module of this instance.
    module: TModule;
    // Instance memory.
    // Memory is either allocated and owned by the instance or imported as already
    // allocated bytesand owned externally. For these cases unique_ptr would
    // either have a normal deleter or no-op deleter respectively
    memory: TBytes;
    // Memory limits.
    memory_limits: TLimits;
    // Hard limit for memory growth in pages, checked when memory is defined
    // as unbounded in module.
    memory_pages_limit: Cardinal;
    // Instance table.
    // Table is either allocated and owned by the instance or imported and owned
    // externally. For these cases unique_ptr would either have a normal deleter
    // or no-op deleter respectively.
    table: table_ptr;
    // Table limits.
    table_limits: TLimits;
    // Instance globals (excluding imported globals).
    globals: TArray<TValue>;
    // Imported functions.
    imported_functions: TArray<TExternalFunction>;
    // Imported globals.
    imported_globals: TArray<TExternalGlobal>;
  public
    constructor From(const module: TModule;
      const memory: TBytes;
      const memory_limits: TLimits;
      const memory_pages_limit: Cardinal;
      table: table_ptr; table_limits: TLimits;
      const globals: TArray<TValue>;
      const imported_functions: TArray<TExternalFunction>;
      const imported_globals: TArray<TExternalGlobal>);
  end;

{$EndRegion}

{$Region 'TVm'}

  TVm = record
  const
    F32AbsMask: Uint32 = $7fffffff;
    F32SignMask: Uint32 = Uint32(not $7fffffff);
    F64AbsMask: Uint64 = $fffffffffffffff;
    F64SignMask: Uint64 = Uint64(not $fffffffffffffff);
  type
    Tv32 = record
      case Integer of
        1: (i32: Uint32);
        2: (f32: Single);
    end;
    Tv64 = record
      case Integer of
        1: (i64: Uint64);
        2: (f64: Double);
    end;
  private
    instance: PInstance;
    code: TCode;
    memory: TBytes;
    func_type: TFuncType;
    stack: TOperandStack;
    pc: PByte;
    vi: Uint64;
    function CheckLoad<SrcT>: Boolean; inline;
    function LoadFromMemory<T: record>: T; inline;
    function CheckStore<DstT>: Boolean; inline;
    procedure StoreToMemory<T>(const value: T);
    procedure Branch(arity: Uint32); inline;
    // Increases the size of memory by delta_pages.
    function GrowMemory(deltaPages, memoryPagesLimit: Uint32): Uint32; inline;
  public
    procedure Init(instance: PInstance; func_idx: TFuncIdx; const args: PValue);
    function Execute(var ctx: TExecutionContext): TExecutionResult;
  end;

{$EndRegion}

{$Region 'PByteHelper'}

  PByteHelper = record helper for PByte
    function read<T>: T; inline;
    procedure store<T>(offset: Cardinal; value: T); inline;
    function load<T>(offset: Cardinal): T; inline;
  end;

{$EndRegion}

{$Region 'execute functions'}

// Execute a function from an instance with execution context
// starting with default depth of 0.
// Arguments and behavior is the same as in the other execute.
function Execute(instance: PInstance; func_idx: TFuncIdx;
  const args: PValue): TExecutionResult; inline; overload;

// Execute a function from an instance.
// Parameters
//   instance  The instance.
//   func_idx  The function index. MUST be a valid index, otherwise undefined behaviour
//             (including crash) happens.
//   args      The pointer to the arguments. The number of items and their types must
//             match the expected number of input parameters of the function, otherwise
//             undefined behaviour (including crash) happens.
//   ctx       Execution context.
function Execute(instance: PInstance; func_idx: TFuncIdx;
  const args: PValue; var ctx: TExecutionContext): TExecutionResult; overload;

{$EndRegion}

implementation

function rotl(lhs, rhs: Uint32): Uint32;
const
  num_bits = sizeof(Uint32);
begin
  var k := rhs and (num_bits - 1);
  if k = 0 then exit(lhs);
  Result := (lhs shl k) or (lhs shr (num_bits - k));
end;

function rotr(lhs, rhs: Uint32): Uint32;
const
  num_bits = sizeof(Uint32);
begin
  var k := rhs and (num_bits - 1);
  if k = 0 then exit(lhs);
  Result := (lhs shr k) or (lhs shl (num_bits - k));
end;

function __builtin_clz(x: Uint32): Uint32;
{$IF Defined(CPUX64)}
asm
  BSR     ECX,ECX
  NEG     ECX
  ADD     ECX,31
  MOV     EAX,ECX
{$ENDIF}
{$IF Defined(CPUX86)}
asm
  BSR     EAX,EAX
  NEG     EAX
  ADD     EAX,31
{$ENDIF}
end;

function __builtin_ctz(x: Uint32): Uint32;
begin

end;

function __builtin_clzll(x: Uint64): Uint64;
begin

end;

function __builtin_ctzll(x: Uint64): Uint64;
begin

end;

function clz32(value: Uint64): Uint64; inline;
begin
  if value = 0 then
    Result := 32
  else
    Result := __builtin_clz(value);
end;

function ctz32(value: Uint32): Uint32; inline;
begin
  if value = 0 then
    Result := 32
  else
    Result := __builtin_ctz(value);
end;

function popcount32(value: Uint32): Uint32; inline;
begin

end;

function clz64(value: Uint64): Uint64; inline;
begin
  if value = 0 then
    Result := 64
  else
    Result := __builtin_clzll(value);
end;

function ctz64(value: Uint64): Uint64; inline;
begin
  if value = 0 then
    Result := 64
  else
    Result := __builtin_ctzll(value);
end;

function popcount64(value: Uint64): Uint64; inline;
begin

end;

{$Region 'TExecutionResult'}

constructor TExecutionResult.From(const value: TValue);
begin
  Self.has_value := True;
  Self.value := value;
end;

constructor TExecutionResult.From(success: Boolean);
begin
  Self.trapped := not success;
end;

{$EndRegion}

{$Region 'TExecutionContext.TGuard'}

constructor TExecutionContext.TGuard.Create(ctx: TExecutionContext);
begin
  Self.m_execution_context := ctx;
end;

destructor TExecutionContext.TGuard.Destroy;
begin
  Dec(m_execution_context.depth);
  inherited;
end;

{$EndRegion}

{$Region 'TExecutionContext'}

function TExecutionContext.increment_call_depth: TGuard;
begin
  Inc(depth);
  Result := TGuard.Create(Self);
end;

{$EndRegion}

{$Region 'ExecuteFunction'}

constructor TExecuteFunction.Create(instance: PInstance; func_idx: TFuncIdx);
begin
  inherited Create;
  m_instance := instance;
  m_func_idx := func_idx;
end;

constructor TExecuteFunction.Create(f: THostFunctionPtr);
begin
  inherited Create;
  m_host_function := f;
end;

constructor TExecuteFunction.Create(f: THostFunctionPtr; host_context: TObject);
begin
  inherited Create;
  m_host_function := f;
  m_host_context := host_context;
end;

function TExecuteFunction.Call(instance: PInstance; const args: PValue;
  var ctx: TExecutionContext): TExecutionResult;
begin
  if m_instance <> nil then
    Result := execute(m_instance, m_func_idx, args, ctx)
  else
    Result := m_host_function(m_host_context, instance, args, ctx);
end;

function TExecuteFunction.GetHostFunction: THostFunctionPtr;
begin
  Result := m_host_function;
end;

{$EndRegion}

{$Region 'TExternalFunction'}

constructor TExternalFunction.From(const func: TExecuteFunction; const typ: TFuncType);
begin
  Self.func := func;
  input_types := TSpan<TValType>.From(@typ.inputs[0], Length(typ.inputs));
  output_types := TSpan<TValType>.From(@typ.outputs[0], Length(typ.outputs));
end;

constructor TExternalFunction.From(const func: TExecuteFunction; const input_types,
  output_types: TSpan<TValType>);
begin
  Self.func := func;
  Self.input_types := input_types;
  Self.output_types := output_types;
end;

{$EndRegion}

{$Region 'TInstance'}

constructor TInstance.From(const module: TModule; const memory: TBytes;
  const memory_limits: TLimits; const memory_pages_limit: Cardinal;
  table: table_ptr; table_limits: TLimits;
  const globals: TArray<TValue>;
  const imported_functions: TArray<TExternalFunction>;
  const imported_globals: TArray<TExternalGlobal>);
begin
  Self.module := module;
  Self.memory := memory;
  Self.memory_limits := memory_limits;
  Self.memory_pages_limit := memory_pages_limit;
  Self.table := table;
  Self.table_limits := table_limits;
  Self.globals := globals;
  Self.imported_functions := imported_functions;
  Self.imported_globals := imported_globals;
end;

{$EndRegion}

{$Region 'PByteHelper'}

function PByteHelper.read<T>: T;
type Pt = ^T;
begin
  Result := Pt(Self)^;
  Inc(Self, sizeof(T));
end;

procedure PByteHelper.store<T>(offset: Cardinal; value: T);
type Pt = ^T;
begin
  Pt(Self + offset)^ := value;
end;

function PByteHelper.load<T>(offset: Cardinal): T;
type Pt = ^T;
begin
  Result := Pt(Self + offset)^;
end;

{$EndRegion}

{$Region 'TVm'}

procedure TVm.Init(instance: PInstance; func_idx: TFuncIdx; const args: PValue);
begin
  Self.instance := instance;
  Self.code := instance.module.get_code(func_idx);
  Self.memory := instance.memory;
  Self.func_type := instance.module.get_function_type(func_idx);
  Self.stack := TOperandStack.From(args, Length(func_type.inputs), code.local_count, code.max_stack_height);
  Self.pc := @code.instructions[0];
end;

function TVm.CheckLoad<SrcT>: Boolean;
var
  address, offset: Int32;
begin
  address := stack.Top.AsInt32;
  // NOTE: alignment is dropped by the parser
  offset := pc.read<Uint32>;
  vi := Uint64(address) + offset;
  // Addressing is 32-bit, but we keep the value as 64-bit to detect overflows.
  Result := vi + sizeof(SrcT) <= Length(memory);
end;

function TVm.LoadFromMemory<T>: T;
type Pt = ^T;
begin
  var pv: PByte := @memory[0];
  Inc(pv, vi);
  Result := Pt(pv)^;
end;

function TVm.CheckStore<DstT>: Boolean;
var
  address, offset: Int32;
begin
  address := stack.Pop.AsInt32;
  // NOTE: alignment is dropped by the parser
  offset := pc.read<Uint32>;
  vi := Uint64(address) + offset;
  // Addressing is 32-bit, but we keep the value as 64-bit to detect overflows.
  Result := vi + sizeof(DstT) <= Length(memory);
end;

procedure TVm.StoreToMemory<T>(const value: T);
begin
  var pv: PByte := @memory[0];
  pv.store(vi, value);
end;

procedure TVm.Branch(arity: Uint32);
var
  code_offset, stack_drop: Uint32;
  r: TValue;
begin
  code_offset := pc.read<Uint32>;
  stack_drop := pc.read<Uint32>;

  pc := PByte(@code.instructions) + code_offset;

  // When branch is taken, additional stack items must be dropped.
  assert(Integer(stack_drop) >= 0);
  assert(stack.Size >= stack_drop + arity);
  if arity <> 0 then
  begin
    assert(arity = 1);
    r := stack.top^;
    stack.drop(stack_drop);
    stack.top^ := r;
  end
  else
    stack.drop(stack_drop);
end;

function TVm.GrowMemory(deltaPages, memoryPagesLimit: Uint32): Uint32;
begin
  var curPages := Length(memory) div PageSize;
  // These Assertions are guaranteed by allocation in instantiate
  // and this function for subsequent increases.
  Assert(Length(memory) mod PageSize = 0);
  Assert(memoryPagesLimit <= MaxMemoryPagesLimit);
  Assert(curPages <= memoryPagesLimit);
  var newPages := Uint64(curPages) + deltaPages;
  if newPages > memoryPagesLimit then
    exit(Uint32(-1));
  try
    // newPages <= memory_pages_limit <= MaxMemoryPagesLimit guarantees multiplication
    // will not overflow Uint32.
    Assert(newPages * PageSize <= Uint32.MaxValue);
    SetLength(memory, newPages * PageSize);
    exit(Uint32(curPages));
  except
    exit(Uint32(-1));
  end;
end;

function invoke_function(const func_type: TFuncType; func_idx: Uint32;
  instance: PInstance; var stack: TOperandStack; var ctx: TExecutionContext): Boolean; inline;
begin
  var num_args := Length(func_type.inputs);
  Assert(stack.Size >= num_args);
  var call_args := PValue(PByte(stack.rend) - num_args);

  var ctx_guard := ctx.increment_call_depth;
  var ret := Execute(instance, TFuncIdx(func_idx), call_args, ctx);

  // Bubble up traps
  if ret.trapped then
    exit(false);

  stack.drop(num_args);

  var num_outputs := Length(func_type.outputs);
  // NOTE: we can assume these two from validation
  Assert(num_outputs <= 1);
  Assert(ret.has_value = (num_outputs = 1));
  // Push back the result
  if num_outputs <> 0 then
    stack.push(ret.value);
  Result := True;
end;

function TVm.Execute(var ctx: TExecutionContext): TExecutionResult;
label
  traps, ends;
var
  instruction: TInstruction;
begin
  repeat
    instruction := TInstruction(pc^);
    Inc(pc);
    case instruction of
      TInstruction.unreachable:
        goto traps;
      TInstruction.nop, TInstruction.block, TInstruction.loop:
        ;
      TInstruction.if_:
        begin
          if stack.pop.AsUint32 <> 0 then
            pc := pc + sizeof(Uint32)  // Skip the immediate for else instruction.
          else
          begin
            var target_pc := pc.read<Uint32>;
            pc := PByte(@code.instructions[0]) + target_pc;
          end;
        end;
      TInstruction.else_:
        begin
          // We reach else only after executing if block ("then" part),
          // so we need to skip else block now.
          var target_pc := pc.read<Uint32>;
          pc := PByte(@code.instructions[0]) + target_pc;
        end;
      TInstruction.end_:
        begin
          // End execution if it's a final end instruction.
          if pc = @code.instructions[Length(code.instructions)] then
            goto ends;
        end;
      TInstruction.br, TInstruction.br_if, TInstruction.return_:
        begin
          var arity := pc.read<Uint32>;
          // Check condition for br_if.
          if (instruction = TInstruction.br_if) and (stack.pop.AsUint32 = 0) then
            pc := pc + BranchImmediateSize;
          Branch(arity);
        end;
      TInstruction.br_table:
        begin
          var br_table_size := pc.read<Uint32>;
          var arity := pc.read<Uint32>;
          var br_table_idx := stack.pop.AsUint32;
          var label_idx_offset: Uint32;
          if br_table_idx < br_table_size then
            label_idx_offset := br_table_idx * BranchImmediateSize
          else
            label_idx_offset := br_table_size * BranchImmediateSize;
          pc := pc + label_idx_offset;
          Branch(arity);
        end;
      TInstruction.call:
        begin
          var called_func_idx := pc.read<Uint32>;
          var called_func_type := instance.module.get_function_type(called_func_idx);
          if not invoke_function(called_func_type, called_func_idx, instance, stack, ctx) then
            goto traps;
        end;
      TInstruction.call_indirect:
        begin
          assert(instance.table <> nil);
          var expected_type_idx := pc.read<Uint32>;
          assert(expected_type_idx < Length(instance.module.typesec));
          var elem_idx := stack.pop.AsUint32;
          if elem_idx >= Length(instance.table^) then
            goto traps;

          var called_func := instance.table^[elem_idx];
          if called_func.instance = nil then
            // Table element not initialized.
            goto traps;

          // check actual type against expected type
          var actual_type := called_func.instance.module.get_function_type(called_func.func_idx);
          var expected_type := instance.module.typesec[expected_type_idx];
          if not expected_type.Equals(actual_type) then
            goto traps;
          if not invoke_function(actual_type, called_func.func_idx, called_func.instance, stack, ctx) then
            goto traps;
        end;
      TInstruction.drop:
        stack.pop;
      TInstruction.select:
        begin
          var condition := stack.pop.AsUint32;
          // NOTE: these two are the same type (ensured by validation)
          var val2 := stack.pop;
          var val1 := stack.pop;
          if condition = 0 then
            stack.push(val2)
          else
            stack.push(val1);
        end;
      TInstruction.local_get:
        begin
          var idx := pc.read<Uint32>;
          stack.push(stack.local(idx)^);
        end;
      TInstruction.local_set:
        begin
          var idx := pc.read<Uint32>;
          stack.local(idx)^ := stack.pop;
        end;
      TInstruction.local_tee:
        begin
          var idx := pc.read<Uint32>;
          stack.local(idx)^ := stack.top^;
        end;
      TInstruction.global_get:
        begin
          var idx := pc.read<Uint32>;
          assert(idx < Length(instance.imported_globals) + Length(instance.globals));
          if (idx < Length(instance.imported_globals)) then
            stack.push(instance.imported_globals[idx].value)
          else
          begin
            var module_global_idx := idx - Length(instance.imported_globals);
            assert(module_global_idx < Length(instance.module.globalsec));
            stack.push(instance.globals[module_global_idx]);
          end;
        end;
      TInstruction.global_set:
        begin
          var idx := pc.read<Uint32>;
          if idx < Length(instance.imported_globals) then
          begin
            assert(instance.imported_globals[idx].typ.is_mutable);
            instance.imported_globals[idx].value := stack.pop;
          end
          else
          begin
            var module_global_idx := idx - Length(instance.imported_globals);
            assert(module_global_idx < Length(instance.module.globalsec));
            assert(instance.module.globalsec[module_global_idx].typ.is_mutable);
            instance.globals[module_global_idx] := stack.pop;
          end;
        end;
      TInstruction.i32_load:
        begin
          if not CheckLoad<Uint32> then goto traps;
          stack.Top.i32 := LoadFromMemory<Uint32>;
        end;
      TInstruction.i64_load:
        begin
          if not CheckLoad<Uint64> then goto traps;
          stack.Top.i64 := LoadFromMemory<Uint64>;
        end;
      TInstruction.f32_load:
        begin
          if not CheckLoad<Single> then goto traps;
          stack.Top.f32 := LoadFromMemory<Single>;
        end;
      TInstruction.f64_load:
        begin
          if not CheckLoad<Double> then goto traps;
          stack.Top.f64 := LoadFromMemory<Double>;
        end;
      TInstruction.i32_load8_s:
        begin
          if not CheckLoad<Int8> then goto traps;
          stack.Top.i32 := LoadFromMemory<Int8>;
        end;
      TInstruction.i32_load8_u:
        begin
          if not CheckLoad<Uint8> then goto traps;
          stack.Top.i32 := LoadFromMemory<Uint8>;
        end;
      TInstruction.i32_load16_s:
        begin
          if not CheckLoad<Int16> then goto traps;
          stack.Top.i32 := LoadFromMemory<Int16>;
        end;
      TInstruction.i32_load16_u:
        begin
          if not CheckLoad<Uint8> then goto traps;
          stack.Top.i32 := LoadFromMemory<Uint8>;
        end;
      TInstruction.i64_load8_s:
        begin
          if not CheckLoad<Int8> then goto traps;
          stack.Top.i64 := LoadFromMemory<Int8>;
        end;
      TInstruction.i64_load8_u:
        begin
          if not CheckLoad<Uint8> then goto traps;
          stack.Top.i64 := LoadFromMemory<Uint8>;
        end;
      TInstruction.i64_load16_s:
        begin
          if not CheckLoad<Int16> then goto traps;
          stack.Top.i64 := LoadFromMemory<Int16>;
        end;
      TInstruction.i64_load16_u:
        begin
          if not CheckLoad<Uint16> then goto traps;
          stack.Top.i64 := LoadFromMemory<Uint16>;
        end;
      TInstruction.i64_load32_s:
        begin
          if not CheckLoad<Int32> then goto traps;
          stack.Top.i64 := LoadFromMemory<Int32>;
        end;
      TInstruction.i64_load32_u:
        begin
          if not CheckLoad<Uint32> then goto traps;
          stack.Top.i64 := LoadFromMemory<Uint32>;
        end;
      TInstruction.i32_store:
        begin
          var value := stack.Pop.i32;
          if not CheckStore<Uint32> then goto traps;
          StoreToMemory<Uint32>(value);
        end;
      TInstruction.i64_store:
        begin
          var value := stack.Pop.i64;
          if not CheckStore<Int64> then goto traps;
          StoreToMemory<Int64>(value);
        end;
      TInstruction.f32_store:
        begin
          var value := stack.Pop.f32;
          if not CheckStore<Single> then goto traps;
          StoreToMemory<Single>(value);
        end;
      TInstruction.f64_store:
        begin
          var value := stack.Pop.f64;
          if not CheckStore<Double> then goto traps;
          StoreToMemory<Double>(value);
        end;
      TInstruction.i32_store8, TInstruction.i64_store8:
        begin
          var value := stack.Pop.i64;
          if not CheckStore<Uint8> then goto traps;
          StoreToMemory<Uint8>(value);
        end;
      TInstruction.i32_store16, TInstruction.i64_store16:
        begin
          var value := stack.Pop.i64;
          if not CheckStore<Uint16> then goto traps;
          StoreToMemory<Uint16>(value);
        end;
      TInstruction.i64_store32:
        begin
          var value := stack.Pop.i64;
          if not CheckStore<Uint32> then goto traps;
          StoreToMemory<Uint32>(value);
        end;
      TInstruction.memory_size:
        begin
          assert(Length(memory) mod PageSize = 0);
          stack.push(TValue.From(Uint32(Length(memory) div PageSize)));
        end;
      TInstruction.memory_grow:
        stack.top.i64 := GrowMemory(stack.top.AsUint32, instance.memory_pages_limit);
      TInstruction.i32_const, TInstruction.f32_const:
        begin
          var value := pc.read<Uint32>;
          stack.push(value);
        end;
      TInstruction.i64_const, TInstruction.f64_const:
        begin
          var value := pc.read<Int64>;
          stack.push(value);
        end;
      TInstruction.i32_eqz:
        stack.top.i32 := Uint32(stack.top.AsUint32 = 0);
      TInstruction.i32_eq:
        begin
          var a := stack.pop.AsUint32;
          var b := stack.top.AsUint32;
          stack.top.i32 := Ord(a = b);
        end;
      TInstruction.i32_ne:
        begin
          var a := stack.pop.AsUint32;
          var b := stack.top.AsUint32;
          stack.top.i32 := Ord(a <> b);
        end;
      TInstruction.i32_lt_s:
        begin
          var a := stack.pop.AsInt32;
          var b := stack.top.AsInt32;
          stack.top.i32 := Ord(a < b);
        end;
      TInstruction.i32_lt_u:
        begin
          var a := stack.pop.AsUint32;
          var b := stack.top.AsUint32;
          stack.top.i32 := Ord(a < b);
        end;
      TInstruction.i32_gt_s:
        begin
          var a := stack.pop.AsInt32;
          var b := stack.top.AsInt32;
          stack.top.i32 := Ord(a > b);
        end;
      TInstruction.i32_gt_u:
        begin
          var a := stack.pop.AsUint32;
          var b := stack.top.AsUint32;
          stack.top.i32 := Ord(a > b);
        end;
      TInstruction.i32_le_s:
        begin
          var a := stack.pop.AsInt32;
          var b := stack.top.AsInt32;
          stack.top.i32 := Ord(a <= b);
        end;
      TInstruction.i32_le_u:
        begin
          var a := stack.pop.AsUint32;
          var b := stack.top.AsUint32;
          stack.top.i32 := Ord(a <= b);
        end;
      TInstruction.i32_ge_s:
        begin
          var a := stack.pop.AsInt32;
          var b := stack.top.AsInt32;
          stack.top.i32 := Ord(a >= b);
        end;
      TInstruction.i32_ge_u:
        begin
          var a := stack.pop.AsUint32;
          var b := stack.top.AsUint32;
          stack.top.i32 := Ord(a >= b);
        end;
      TInstruction.i64_eqz:
        stack.top.i32 := Ord(stack.top.i64 = 0);
      TInstruction.i64_eq:
        begin
          var a := stack.pop.AsInt64;
          var b := stack.top.AsInt64;
          stack.top.i32 := Ord(a = b);
        end;
      TInstruction.i64_ne:
        begin
          var a := stack.pop.AsInt64;
          var b := stack.top.AsInt64;
          stack.top.i32 := Ord(a <> b);
        end;
      TInstruction.i64_lt_s:
        begin
          var a := stack.pop.AsUint64;
          var b := stack.top.AsUint64;
          stack.top.i32 := Ord(a < b);
        end;
      TInstruction.i64_lt_u:
        begin
          var a := stack.pop.AsInt64;
          var b := stack.top.AsInt64;
          stack.top.i32 := Ord(a < b);
        end;
      TInstruction.i64_gt_s:
        begin
          var a := stack.pop.AsUint64;
          var b := stack.top.AsUint64;
          stack.top.i32 := Ord(a > b);
        end;
      TInstruction.i64_gt_u:
        begin
          var a := stack.pop.AsInt64;
          var b := stack.top.AsInt64;
          stack.top.i32 := Ord(a > b);
        end;
      TInstruction.i64_le_s:
        begin
          var a := stack.pop.AsUint64;
          var b := stack.top.AsUint64;
          stack.top.i32 := Ord(a <= b);
        end;
      TInstruction.i64_le_u:
        begin
          var a := stack.pop.AsInt64;
          var b := stack.top.AsInt64;
          stack.top.i32 := Ord(a <= b);
        end;
      TInstruction.i64_ge_s:
        begin
          var a := stack.pop.AsUint64;
          var b := stack.top.AsUint64;
          stack.top.i32 := Ord(a >= b);
        end;
      TInstruction.i64_ge_u:
        begin
          var a := stack.pop.AsInt64;
          var b := stack.top.AsInt64;
          stack.top.i32 := Ord(a >= b);
        end;
      TInstruction.f32_eq:
        begin
          var a := stack.pop.AsSingle;
          var b := stack.top.AsSingle;
          stack.top.i32 := Ord(SameValue(a, b));
        end;
      TInstruction.f32_ne:
        begin
          var a := stack.pop.AsSingle;
          var b := stack.top.AsSingle;
          stack.top.i32 := Ord(not SameValue(a, b));
        end;
      TInstruction.f32_lt:
        begin
          var a := stack.pop.AsSingle;
          var b := stack.top.AsSingle;
          stack.top.i32 := Ord(a < b);
        end;
      TInstruction.f32_gt:
        begin
          var a := stack.pop.AsSingle;
          var b := stack.top.AsSingle;
          stack.top.i32 := Ord(a > b);
        end;
      TInstruction.f32_le:
        begin
          var a := stack.pop.AsSingle;
          var b := stack.top.AsSingle;
          stack.top.i32 := Ord(a <= b);
        end;
      TInstruction.f32_ge:
        begin
          var a := stack.pop.AsSingle;
          var b := stack.top.AsSingle;
          stack.top.i32 := Ord(a >= b);
        end;
      TInstruction.f64_eq:
        begin
          var a := stack.pop.AsDouble;
          var b := stack.top.AsDouble;
          stack.top.i32 := Ord(SameValue(a, b));
        end;
      TInstruction.f64_ne:
        begin
          var a := stack.pop.AsDouble;
          var b := stack.top.AsDouble;
          stack.top.i32 := Ord(not SameValue(a, b));
        end;
      TInstruction.f64_lt:
        begin
          var a := stack.pop.AsDouble;
          var b := stack.top.AsDouble;
          stack.top.i32 := Ord(a < b);
        end;
      TInstruction.f64_gt:
        begin
          var a := stack.pop.AsDouble;
          var b := stack.top.AsDouble;
          stack.top.i32 := Ord(a > b);
        end;
      TInstruction.f64_le:
        begin
          var a := stack.pop.AsDouble;
          var b := stack.top.AsDouble;
          stack.top.i32 := Ord(a <= b);
        end;
      TInstruction.f64_ge:
        begin
          var a := stack.pop.AsDouble;
          var b := stack.top.AsDouble;
          stack.top.i32 := Ord(a >= b);
        end;
      TInstruction.i32_clz:
        stack.top.i32 := clz32(stack.top.i32);
      TInstruction.i32_ctz:
        stack.top.i32 := ctz32(stack.top.i32);
      TInstruction.i32_popcnt:
        stack.top.i32 := popcount32(stack.top.i32);
      TInstruction.i32_add:
        begin
          var a := stack.pop.AsUint32;
          var b := stack.top.AsUint32;
          stack.top.i32 := a + b;
        end;
      TInstruction.i32_sub:
        begin
          var a := stack.pop.AsUint32;
          var b := stack.top.AsUint32;
          stack.top.i32 := a - b;
        end;
      TInstruction.i32_mul:
        begin
          var a := stack.pop.AsUint32;
          var b := stack.top.AsUint32;
          stack.top.i32 := a * b;
        end;
      TInstruction.i32_div_s:
        begin
          var rhs := stack.pop.AsInt32;
          var lhs := stack.top.AsInt32;
          if (rhs = 0) or (lhs = Int32.MinValue) and (rhs = -1) then
            goto traps;
          stack.top.i32 := lhs div rhs;
        end;
      TInstruction.i32_div_u:
        begin
          var rhs := stack.pop.AsUint32;
          if rhs = 0 then
            goto traps;
          var lhs := stack.top.AsUint32;
          stack.top.i32 := lhs div rhs;
        end;
      TInstruction.i32_rem_s:
      begin
        var rhs := stack.pop.AsInt32;
        if rhs = 0 then
          goto traps;
        var lhs := stack.top.AsInt32;
        if (lhs = Int32.MinValue) and (rhs = -1) then
          stack.top.i32 := 0
        else
          stack.top.i32 := lhs mod rhs;
      end;
      TInstruction.i32_rem_u:
      begin
        var rhs := stack.pop.AsUint32;
        if rhs = 0 then
          goto traps;
        var lhs := stack.top.AsUint32;
        stack.top.i32 := lhs mod rhs;
      end;
      TInstruction.i32_and:
        begin
          var a := stack.pop.AsUint32;
          var b := stack.top.AsUint32;
          stack.top.i32 := a and b;
        end;
      TInstruction.i32_or:
        begin
          var a := stack.pop.AsUint32;
          var b := stack.top.AsUint32;
          stack.top.i32 := a or b;
        end;
      TInstruction.i32_xor:
        begin
          var a := stack.pop.AsUint32;
          var b := stack.top.AsUint32;
          stack.top.i32 := a xor b;
        end;
      TInstruction.i32_shl:
        begin
          var a := stack.pop.AsUint32;
          var b := stack.top.AsUint32 and (sizeof(Uint32) * 8 - 1);
          stack.top.i32 := a shl b;
        end;
      TInstruction.i32_shr_s:
        begin
          var a := stack.pop.AsInt32;
          var b := stack.top.AsInt32 and (sizeof(Int32) * 8 - 1);
          stack.top.i32 := a shr b;
        end;
      TInstruction.i32_shr_u:
        begin
          var a := stack.pop.AsUint32;
          var b := stack.top.AsUint32 and (sizeof(Uint32) * 8 - 1);
          stack.top.i32 := a shr b;
        end;
      TInstruction.i32_rotl:
        begin
          var a := stack.pop.AsUint32;
          var b := stack.top.AsUint32 and (sizeof(Uint32) * 8 - 1);
          stack.top.i32 := rotl(a, b);
        end;
      TInstruction.i32_rotr:
        begin
          var a := stack.pop.AsUint32;
          var b := stack.top.AsUint32 and (sizeof(Uint32) * 8 - 1);
          stack.top.i32 := rotr(a, b);
        end;

      TInstruction.i64_clz:
        stack.top.i64 := clz64(stack.top.i64);
      TInstruction.i64_ctz:
        stack.top.i64 := ctz64(stack.top.i64);
      TInstruction.i64_popcnt:
        stack.top.i64 := popcount64(stack.top.i64);
      TInstruction.i64_add:
        begin
          var a := stack.pop.AsInt64;
          var b := stack.top.AsInt64;
          stack.top.i64 := a + b;
        end;
      TInstruction.i64_sub:
        begin
          var a := stack.pop.AsInt64;
          var b := stack.top.AsInt64;
          stack.top.i64 := a - b;
        end;
      TInstruction.i64_mul:
        begin
          var a := stack.pop.AsInt64;
          var b := stack.top.AsInt64;
          stack.top.i64 := a * b;
        end;
      TInstruction.i64_div_s:
        begin
          var rhs := stack.pop.AsInt64;
          var lhs := stack.top.AsInt64;
          if (rhs = 0) or (lhs = Int64.MinValue) and (rhs = -1) then
            goto traps;
          stack.top.i64 := lhs div rhs;
        end;
      TInstruction.i64_div_u:
        begin
          var rhs := stack.pop.i64;
          if rhs = 0 then
            goto traps;
          var lhs := stack.top.i64;
          stack.top.i64 := lhs div rhs;
        end;
      TInstruction.i64_rem_s:
        begin
          var rhs := stack.pop.AsUint64;
          if rhs = 0 then
            goto traps;
          var lhs := stack.top.AsUint64;
          if (lhs = Uint64.MinValue) and (rhs = -1) then
            stack.top.i64 := 0
          else
            stack.top.i64 := lhs mod rhs;
        end;
      TInstruction.i64_rem_u:
        begin
          var rhs := stack.pop.i64;
          if rhs = 0 then
            goto traps;
          var lhs := stack.top.i64;
          stack.top.i64 := lhs mod rhs;
        end;
      TInstruction.i64_and:
        begin
          var a := stack.pop.AsInt64;
          var b := stack.top.AsInt64;
          stack.top.i64 := a and b;
        end;
      TInstruction.i64_or:
        begin
          var a := stack.pop.AsInt64;
          var b := stack.top.AsInt64;
          stack.top.i64 := a or b;
        end;
      TInstruction.i64_xor:
        begin
          var a := stack.pop.AsInt64;
          var b := stack.top.AsInt64;
          stack.top.i64 := a xor b;
        end;
      TInstruction.i64_shl:
        begin
          var a := stack.pop.AsInt64;
          var b := stack.top.AsInt64;
          stack.top.i64 := a shl b;
        end;
      TInstruction.i64_shr_s:
        begin
          var a := stack.pop.AsUint64;
          var b := stack.top.AsUint64;
          stack.top.i64 := a shl b;
        end;
      TInstruction.i64_shr_u:
        begin
          var a := stack.pop.AsInt64;
          var b := stack.top.AsInt64;
          stack.top.i64 := a shl b;
        end;
      TInstruction.i64_rotl:
        begin
          var a := stack.pop.AsInt64;
          var b := stack.top.AsInt64;
          stack.top.i64 := rotl(a, b);
        end;
      TInstruction.i64_rotr:
        begin
          var a := stack.pop.AsInt64;
          var b := stack.top.AsInt64;
          stack.top.i64 := rotr(a, b);
        end;

      TInstruction.f32_abs:
        stack.top.f32 := Abs(stack.top.f32);
      TInstruction.f32_neg:
        stack.top.f32 := stack.top.i32 xor F32SignMask;
      TInstruction.f32_ceil:
        if stack.top.AsSingle.IsNan then
          stack.top.f32 := Single.NaN
        else
          stack.top.f32 := Ceil(stack.top.AsSingle);
      TInstruction.f32_floor:
        if stack.top.AsSingle.IsNan then
          stack.top.f32 := Single.NaN
        else
          stack.top.f32 := Floor(stack.top.AsSingle);
      TInstruction.f32_trunc:
        if stack.top.AsSingle.IsNan then
          stack.top.f32 := Single.NaN
        else
          stack.top.f32 := Trunc(stack.top.AsSingle);
      TInstruction.f32_nearest:
        if stack.top.AsSingle.IsNan then
          stack.top.f32 := Single.NaN
        else
          stack.top.f32 := SimpleRoundTo(stack.top.AsSingle, 0);
      TInstruction.f32_sqrt:
        stack.top.f32 := Sqrt(stack.top.AsSingle);
      TInstruction.f32_add:
        begin
          var a := stack.pop.AsSingle;
          var b := stack.top.AsSingle;
          stack.top.f32 := a + b;
        end;
      TInstruction.f32_sub:
        begin
          var a := stack.pop.AsSingle;
          var b := stack.top.AsSingle;
          stack.top.f32 := a - b;
        end;
      TInstruction.f32_mul:
        begin
          var a := stack.pop.AsSingle;
          var b := stack.top.AsSingle;
          stack.top.f32 := a * b;
        end;
      TInstruction.f32_div:
        begin
          var a := stack.pop.AsSingle;
          var b := stack.top.AsSingle;
          stack.top.f32 := a / b;
        end;
      TInstruction.f32_min:
        begin
          var a: Single := stack.pop.AsSingle;
          var b: Single := stack.top.AsSingle;
          if a.IsNan or b.IsNan then
            stack.top.f32 := Single.NaN
          else if (a = 0) and (b = 0) and
            ((Tv32(a).i32 and F32SignMask <> 0) or
             (Tv32(b).i32 and F32SignMask <> 0)) then
            stack.top.f32 := -0.0
          else if b < a then
            stack.top.f32 := b
          else
            stack.top.f32 := a;
        end;
      TInstruction.f32_max:
        begin
          var a: Single := stack.pop.AsSingle;
          var b: Single := stack.top.AsSingle;
          if a.IsNan or b.IsNan then
            stack.top.f32 := Single.NaN
          else if (a = 0) and (b = 0) and
            ((Tv32(a).i32 and F32SignMask <> 0) or
             (Tv32(b).i32 and F32SignMask <> 0)) then
            stack.top.f32 := -0.0
          else if a < b then
            stack.top.f32 := b
          else
            stack.top.f32 := a;
        end;
      TInstruction.f32_copysign:
        begin
          var a := stack.pop.i32;
          var b := stack.top.i32 and F32SignMask;
          stack.top.i32 := (a and F32AbsMask) or b;
        end;
      TInstruction.f64_abs:
        stack.top.f64 := Abs(stack.top.f64);
      TInstruction.f64_neg:
        stack.top.i64 := stack.top.i64 xor F64SignMask;
      TInstruction.f64_ceil:
        if stack.top.AsDouble.IsNan then
          stack.top.f64 := Double.NaN
        else
          stack.top.f64 := Ceil(stack.top.AsDouble);
      TInstruction.f64_floor:
        if stack.top.AsDouble.IsNan then
          stack.top.f64 := Double.NaN
        else
          stack.top.f64 := Floor(stack.top.AsDouble);
      TInstruction.f64_trunc:
        if stack.top.AsDouble.IsNan then
          stack.top.f64 := Double.NaN
        else
          stack.top.f64 := Trunc(stack.top.AsDouble);
      TInstruction.f64_nearest:
        if stack.top.AsDouble.IsNan then
          stack.top.f64 := Double.NaN
        else
          stack.top.f64 := SimpleRoundTo(stack.top.AsDouble, 0);
      TInstruction.f64_sqrt:
        stack.top.f64 := Sqrt(stack.top.AsDouble);
      TInstruction.f64_add:
        begin
          var a := stack.pop.AsDouble;
          var b := stack.top.AsDouble;
          stack.top.f64 := a + b;
        end;
      TInstruction.f64_sub:
        begin
          var a := stack.pop.AsDouble;
          var b := stack.top.AsDouble;
          stack.top.f64 := a - b;
        end;
      TInstruction.f64_mul:
        begin
          var a := stack.pop.AsDouble;
          var b := stack.top.AsDouble;
          stack.top.f64 := a * b;
        end;
      TInstruction.f64_div:
        begin
          var a := stack.pop.AsDouble;
          var b := stack.top.AsDouble;
          stack.top.f64 := a / b;
        end;
      TInstruction.f64_min:
        begin
          var a: Double := stack.pop.AsDouble;
          var b: Double := stack.top.AsDouble;
          if a.IsNan or b.IsNan then
            stack.top.f64 := Double.NaN
          else if (a = 0) and (b = 0) and
            ((Tv64(a).i64 and F64SignMask <> 0) or
             (Tv64(b).i64 and F64SignMask <> 0)) then
            stack.top.f64 := -0.0
          else if b < a then
            stack.top.f64 := b
          else
            stack.top.f64 := a;
        end;
      TInstruction.f64_max:
        begin
          var a: Double := stack.pop.AsDouble;
          var b: Double := stack.top.AsDouble;
          if a.IsNan or b.IsNan then
            stack.top.f64 := Double.NaN
          else if (a = 0) and (b = 0) and
            ((Tv64(a).i64 and F64SignMask <> 0) or
             (Tv64(b).i64 and F64SignMask <> 0)) then
            stack.top.f64 := -0.0
          else if a < b then
            stack.top.f64 := b
          else
            stack.top.f64 := a;
        end;
      TInstruction.f64_copysign:
        begin
          var a := stack.pop.i64;
          var b := stack.top.i64 and F64SignMask;
          stack.top.i64 := (a and F64AbsMask) or b;
        end;

      TInstruction.i32_wrap_i64:
        stack.top.i32 := Uint32(stack.top.i64);
      TInstruction.i32_trunc_f32_s:
        begin
          var a := stack.top.f32;
          if not (a > -2147483904.0) and (a < 2147483648.0) then
            goto traps;
          stack.top.i32 := trunc(a);
        end;
      TInstruction.i32_trunc_f32_u:
        begin
          var a := stack.top.f32;
          if not (a > -1.0) and (a < 4294967296.0) then
            goto traps;
          stack.top.i32 := trunc(a);
        end;
      TInstruction.i32_trunc_f64_s:
        begin
          var a := stack.top.f64;
          if not (a > -2147483649.0) and (a < 2147483648.0) then
            goto traps;
          stack.top.i32 := trunc(a);
        end;
      TInstruction.i32_trunc_f64_u:
        begin
          var a := stack.top.f64;
          if not (a > -1.0) and (a < 4294967296.0) then
            goto traps;
          stack.top.i32 := trunc(a);
        end;
      TInstruction.i64_extend_i32_s:
        stack.top.i64 := int64(stack.top.AsInt32);
      TInstruction.i64_extend_i32_u:
        stack.top.i64 := uint64(stack.top.i32);
      TInstruction.i64_trunc_f32_s:
        begin
          var a := stack.top.f32;
          if not (a > -9223373136366403584.0) and (a < 9223372036854775808.0) then
            goto traps;
          stack.top.i64 := trunc(a);
        end;
      TInstruction.i64_trunc_f32_u:
        begin
          var a := stack.top.f32;
          if not (a > -1.0) and (a < 18446744073709551616.0) then
            goto traps;
          stack.top.i64 := trunc(a);
        end;
      TInstruction.i64_trunc_f64_s:
        begin
          var a := stack.top.f64;
          if not (a > -9223372036854777856.0) and (a < 9223372036854775808.0) then
            goto traps;
          stack.top.i64 := trunc(a);
        end;
      TInstruction.i64_trunc_f64_u:
        begin
          var a := stack.top.f64;
          if not (a > -1.0) and (a < 18446744073709551616.0) then
            goto traps;
          stack.top.i64 := trunc(a);
        end;
      TInstruction.f32_convert_i32_s:
        stack.top.f32 := stack.top.AsInt32;
      TInstruction.f32_convert_i32_u:
        stack.top.f32 := stack.top.AsUint32;
      TInstruction.f32_convert_i64_s:
        stack.top.f32 := stack.top.AsInt64;
      TInstruction.f32_convert_i64_u:
        stack.top.f32 := stack.top.AsInt64;
      TInstruction.f32_demote_f64:
        stack.top.f32 := stack.top.f64;
      TInstruction.f64_convert_i32_s:
        stack.top.f64 := stack.top.AsInt32;
      TInstruction.f64_convert_i32_u:
        stack.top.f64 := stack.top.AsUint32;
      TInstruction.f64_convert_i64_s:
        stack.top.f64 := stack.top.AsInt64;
      TInstruction.f64_convert_i64_u:
        stack.top.f64 := stack.top.AsUint64;
      TInstruction.f64_promote_f32:
        stack.top.f64 := Double(stack.top.f32);
      TInstruction.i32_reinterpret_f32,
      TInstruction.i64_reinterpret_f64,
      TInstruction.f32_reinterpret_i32,
      TInstruction.f64_reinterpret_i64:
        {reinterpret};
      else
        assert(False, 'unreachable')
    end;
  until False;
ends:
  assert(pc = @code.instructions[Length(code.instructions)]);
  // End of code must be reached.
  assert(stack.size = Length(func_type.outputs));

  if stack.size <> 0 then
    exit(TExecutionResult.From(stack.top^))
  else
    exit(Void);
traps:
    exit(Trap);
end;

{$EndRegion}

{$Region 'execute functions'}

function Execute(instance: PInstance; func_idx: TFuncIdx;
  const args: PValue): TExecutionResult; inline; overload;
var
  ctx: TExecutionContext;
begin
  Result := execute(instance, func_idx, args, ctx);
end;

function Execute(instance: PInstance; func_idx: TFuncIdx;
  const args: PValue; var ctx: TExecutionContext): TExecutionResult;
var
  vm: TVm;
begin
  Assert(ctx.depth >= 0);
  if ctx.depth >= CallStackLimit then
    exit(Trap);

  Assert(Length(instance.module.imported_function_types) = Length(instance.imported_functions));
  if func_idx < Cardinal(Length(instance.imported_functions)) then
    exit(instance.imported_functions[func_idx].func.Call(instance, args, ctx));

  vm.Init(instance, func_idx, args);
  Result := vm.Execute(ctx);
end;

{$EndRegion}

end.

