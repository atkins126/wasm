(* Oz.Wasm: A fast Delphi WebAssembly interpreter
 * Copyright (c) 2021 Tomsk, Marat Shaimardanov
 * SPDX-License-Identifier: (GPL-3.0-or-later OR Apache-2.0)
 *)
unit Oz.Wasm.Parser;

interface

uses
  Oz.Wasm.Utils, Oz.Wasm.Value, Oz.Wasm.Types, Oz.Wasm.Module;

{$T+}
{$SCOPEDENUMS ON}

{$Region 'TWasmParser'}

type
  TParserResult<T> = record
    first: PByte;
    second: T;
  end;

  TWasmParser = record
  private
    procedure raiseEOF;
    function parseByte(const pos, ends: PByte): TParserResult<Byte>;
    function parseValue<T: record>(const pos, ends: PByte): TParserResult<T>;

    // Parses 'expr', i.e. a function's instructions residing in the code section.
    // https://webassembly.github.io/spec/core/binary/instructions.html#binary-expr
    // parameters:
    //   pos       The beginning of the expr binary input.
    //   ends      The end of the binary input.
    //   funcIdx   Index of the function being parsed.
    //   locals    Vector of local type and counts for the function being parsed.
    //   module    Module that this code is part of.
    //   returns   The parsed code.
    function parseExpr(const pos, ends: PByte; funcIidx: TFuncIdx;
      const locals: TArray<TLocals>; const module: TModule): TParserResult<TCode>;

    // Parses a string and validates it against UTF-8 encoding rules.
    // parameters:
    //   pos      The beginning of the string input.
    //   ends     The end of the string input.
    //   returns  The parsed and UTF-8 validated string.
    function parseString(const pos, ends: PByte): TParserResult<System.UTF8String>;

    // Parses the vec of i32 values. This is used in parseExpr.
    function parseVec32(const pos, ends: PByte): TParserResult<TArray<Uint32>>;

    // Validates and converts the given byte to valtype.
    function validateValtype(v: Byte): TValType;
  public
    // Parses input into a Module.
    // parameters:
    //  input    The WebAssembly binary. No need to persist by the caller,
    //           since all relevant parts will be copied.
    //  returns  The parsed module.
    function parse(input: TBytesView): PModule;
  end;

{$EndRegion}

implementation

{$Region 'TWasmParser'}

function TWasmParser.parse(input: TBytesView): PModule;
begin

end;

procedure TWasmParser.raiseEOF;
begin
  raise WasmError.Create('unexpected EOF');
end;

function TWasmParser.parseByte(const pos, ends: PByte): TParserResult<Byte>;
begin
  if pos >= ends then raiseEOF;
  Result.first := pos + 1;
  Result.second := pos^;
end;

function TWasmParser.parseValue<T>(const pos, ends: PByte): TParserResult<T>;
type
  Pt = ^T;
var
  size: Uint32;
begin
  size := sizeof(T);
  if ends - pos < size then raiseEOF;
  Result.first := pos + size;
  Result.second := Pt(pos)^;
end;

function TWasmParser.parseExpr(const pos, ends: PByte; funcIidx: TFuncIdx;
  const locals: TArray<TLocals>; const module: TModule): TParserResult<TCode>;
begin

end;

function TWasmParser.parseString(const pos, ends: PByte): TParserResult<System.UTF8String>;
begin

end;

function TWasmParser.parseVec32(const pos, ends: PByte): TParserResult<TArray<Uint32>>;
begin

end;

function TWasmParser.validateValtype(v: Byte): TValType;
begin

end;

{$EndRegion}

end.

