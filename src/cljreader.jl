"""
File: cljreader.jl
Author: Vishesh Gupta

contains functions that are intended to take a julia expression object and
output an s-expression that is valid in clojure.

Also contains functions to format and print the s-expression, based on what I
feel are sensible indentation rules.

"""
module CLJReader

export read

include("util.jl")
using .Util: mapcat, isform, unescapesym, VECID, DICTID


read(s, t::Bool=false) = string(s)
read(s::Void, t::Bool=false) = "nil"
#read(s::Bool) = string(s)

#= Numbers =#
#read(n::Union{Int, Int8, Int16, Int32, Int64, Int128, BigInt}) = string(n)
#read(n::Union{Float16, Float32, Float64, BigFloat}) = string(n)
read(n::Union{UInt, UInt8, UInt16, UInt32, UInt64, UInt128}, t::Bool=false) =
  string("0x",base(16,n))
read(r::Rational, t::Bool=false) = string(read(r.num, t), "/", read(r.den, t))

#= Characters, doesn't handle unicode and such. =#
function read(c::Char, t::Bool=false)
  if c == '\n'
    return "\\newline"
  elseif c == ' '
    return "\\space"
  elseif c == '\t'
    return "\\tab"
  elseif c == '\f'
    return "\\formfeed"
  elseif c == '\b'
    return "\\backspace"
  elseif c == '\r'
    return "\\return"
  else
    return string("\\",c)
  end
end
#= Strings =#
read(s::AbstractString, t::Bool=false) = string("\"", escape_string(s), "\"")
#= keywords =#
read(k::QuoteNode, t::Bool=false) = k.value == :nothing ? ":nothing" : string(":", read(k.value))
#= symbols =#
read(s::Symbol, t::Bool=false) = s == :nothing ? "nil" : unescapesym(string(s))

"""
Use Util.tosexp in src/util.jl which will take an expression
and convert it into a array style sexp which is a representation of how
julia's internal parser sees things. This sexp is parsed

Expression heads that are not being handled here:
* :comparison - this requires an infix grammar of understanding how to convert
  the entire list of comparison tokens to an s-expression.
  When going from clojure to julia, everything is done as a function call, so to
  go the other way it shouldn't be necessary to deal with this.
  * special, very common cases may be allowed (i.e, x </>/>=/<= y types) to
    support reading raw julia files (that weren't first translated from
    s-expression syntax). This is NOT a priority though.
"""
function read(sexp::Array, toplevel::Bool=false)
  # Special Atoms
  # :// -> rational const.
  if sexp[1] == :call && sexp[2] == ://
    return string(read(sexp[3], toplevel), "/", read(sexp[4], toplevel))
  end
  # :quote -> Symbol (keyword)
  if sexp[1] == :quote && isa(sexp[2], Symbol)
    return string(":",read(sexp[2]))
  end
  
  
  # empty list
  if sexp[1] == :tuple && length(sexp) == 1
    return ()
  end

  # :block -> do
  if sexp[1] == :block
    if length(sexp) == 1
      # (do) -> nil, which I guess is a tiny optimization.
      # it avoids weirdnesses like function(x) end -> (fn [x] (do)), which is
      # bizzare. Better to have  (fn [x] nil) instead.
      return "nil"
    elseif length(sexp) == 2
      return read(sexp[2])
    else
      return ("do", map(read, sexp[2:end])...)
    end
  end

  # :if -> if
  if sexp[1] == :if
    return ("if", map(read, sexp[2:end])...)
  end

  if sexp[1] == :comparison
    if length(sexp) == 4
      return (read(sexp[3]), read(sexp[2]), read(sexp[4]))
    end
  end

  # :let -> let
  if sexp[1] == :let
    return ("let",
            (:vect, mapcat(e->map(read, e[2:end]), sexp[3:end])...),
            read(sexp[2]))
  end

  # :function -> fn (or defn? This is a problem.)
  if sexp[1] == :function
    # sexp[2] is either :call or :tuple
    body = read(sexp[3])
    if sexp[2][1] == :tuple
      # this is an anonymous function
      return ("fn", (:vect, map(read, sexp[2][2:end])...),
              (body[1] == "do" ? body[2:end] : [body])... )
    else
      # this is a named function
      return (toplevel ? "defn" : "fn",
              read(sexp[2][2]), (:vect, map(read, sexp[2][3:end])...),
              (body[1] == "do" ? body[2:end] : [body])... )
    end
  end
  
  # :-> -> fn
  if sexp[1] == :->
    # if the next element is a single symbol, wrap it in a tuple.
    return ("fn",
            isa(sexp[2], Symbol) ? (:vect, read(sexp[2])) : (:vect, map(read, sexp[2][2:end])...),
            read(sexp[3]))
  end
  # := -> def
  # you should only have def at the toplevel. no defing vars inside something.
  if sexp[1] == :(=) && toplevel
    return ("def", map(read, sexp[2:end])...)
  end


  # Macro special forms
  # :macro -> macro definitions should be ignored for now

  # Julia Special Forms
  
  # :ref and :(:) -> aget related
  if sexp[1] == :ref
    return ("aget", map(read, sexp[2:end])...)
  end
  
  if sexp[1] == :(:)
    # should not have more than four forms
    if length(sexp) == 3 && sexp[3] == :end
      return (":", read(sexp[2]))
    end
    return (":", map(read, sexp[2:end])...)
  end
  
  # module related
  # module
  if sexp[1] == :module
    return ("module", read(sexp[3]), map(read, sexp[4][4:end])...)
  end
  # import
  if sexp[1] == :import
    return ("import", map(read, sexp[2:end])...)
  end
  # using
  if sexp[1] == :using
    return ("use", map(read, sexp[2:end])...)
  end
  # export
  if sexp[1] == :export
    return ("export", map(read, sexp[2:end])...)
  end
  
  
  # :. -> (.b a) (dot-access syntax)
  if sexp[1] == :.
    # heads up that sexp[3] should always be a quotenode.
    # TODO one more optimization is that if it looks like
    # (. (. (form) quotenode) quotenode)
    # it can be made into (. (form) quotenode.quotenode) instead.
    if isa(sexp[2], Symbol) && isa(sexp[3], QuoteNode)
      return string(read(sexp[2]), ".", read(sexp[3].value))
    elseif isform(sexp[2]) && isa(sexp[3], QuoteNode)
      s = read(sexp[2])
      if isa(s, AbstractString)
        return string(s, '.', read(sexp[3].value))
      elseif length(sexp[2]) >= 3 && isa(sexp[2][3], QuoteNode)
        return (s[1:end-1]..., string(s[end], '.', read(sexp[3].value)))
      else
        return (".", s, read(sexp[3].value))
      end
    end
  end
  # :(::) -> (:: ) (type definition syntax)
  if sexp[1] == :(::)
    # again, sexp[3] should be a symbol.
    # if it looks like (:: symbol symbol)
    # then we need to do the conversion here directly.
    if all(x->isa(x, Symbol), sexp[2:end])
      return join(sexp[2:end], "::")
    elseif isform(sexp[2]) && isa(sexp[3], Symbol)
      s = read(sexp[2])
      if isa(s,AbstractString)
        return string(s, "::", read(sexp[3]))
      end
    end
    return ("::", map(read, sexp[2:end])...)
  end
  # parameterized types.
  if sexp[1] == :curly
    return ("curly", map(read, sexp[2:end])...)
  end
  if sexp[1] == :&&
    return ("and", map(read, sexp[2:end])...)
  end
  if sexp[1] == :||
    return ("or", map(read, sexp[2:end])...)
  end


  # Literals
  # :vect -> [] (vector literal)
  if sexp[1] == :vect
    return (:vect, map(read, sexp[2:end])...)
  end
  # (:call, :Dict...) -> {} (dict literal)
  if sexp[1] == :call && sexp[2] == :Dict
    return (:dict, map(read,mapcat(x->x[2:end], sexp[3:end]))...)
  end
  if sexp[1] == :tuple
    return (map(read, sexp[2:end])...)
  end


  # :call>:. -> (.b a) (dot-call syntax)
  if sexp[1] == :call && isform(sexp[2]) && sexp[2][1] == :.
    return (read(sexp[2]), map(read, sexp[3:end])...)
  end
  
  # :macrocall -> (@macro ) (macro application)
  # have to write readquoted to make this work.
  # it shouldn't be too hard - just atoms and literals need to be read out.
  if sexp[1] == :macrocall
    return (read(sexp[2]), map(readquoted, sexp[3:end])...)
  end
  
  # :call -> (f a b) (function call)
  if sexp[1] == :call
    return (map(read, sexp[2:end])...)
  end

end

function readquoted(sexp)
  if isform(sexp)
    if sexp[1] == :quote
      # we need to unquote quoted expressions inside quotes
      read(sexp[end])
    elseif sexp[1] == :vect
      (:vect, map(readquoted, sexp[2:end])...)
    elseif sexp[1] == :call && sexp[2] == :Dict
      (:dict, map(readquoted, mapcat(x->x[2:end], sexp[3:end]))...)
    elseif sexp[1] == :tuple
      (map(readquoted, sexp[2:end])...)
    else
      map(readquoted, sexp)
    end
  else
    if isa(sexp, QuoteNode)
      read(sexp.value)
    else
      read(sexp)
    end
  end
end

end
