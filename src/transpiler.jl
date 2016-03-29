module Transpiler

include("reader.jl")
import .Reader
include("parser.jl")
import .Parser
include("cljreader.jl")
import .CLJReader
include("util.jl")
import .Util

export transpile, lisp_str

transpile(str::AbstractString) =
  Util.delevel(map(x -> Reader.read(x...), zip(Parser.parsesexp(str)...)))

detranspile(ex, toplevel=false) =
  CLJReader.read(Util.tosexp(Util.stripmeta(ex)), toplevel)

macro clj_str(str::AbstractString)
  transpile(str)
end

macro jl(ex::Expr)
  detranspile(ex)
end

end

