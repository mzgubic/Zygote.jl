using IRTools: varargs!, inlineable!, pis!, slots!
using IRTools.Inner: argnames!, update!

ignore_sig(T) = all(T -> T <: Type, T.parameters)

@generated function _pullback(ctx::AContext, f, args...)
  T = Tuple{f,args...}
  ignore(T) && return :(f(args...), Pullback{$T}(()))

  iskw = is_kwfunc(f, args...)
  # if it is_kw then `args[1]` are the keyword args, `args[2]` is actual function
  base_T = iskw ? Tuple{args[2:end]...} : T
  hascr, cr_edges = has_chain_rrule(base_T)
  chain_rrule_f = iskw ? :chain_rrule_kw : :chain_rrule
  hascr && return :($chain_rrule_f(f, args...))

  g = try _lookup_grad(T) catch e e end
  !(g isa Tuple) && return :(f(args...), Pullback{$T}((f,)))
  meta, forw, _ = g
  argnames!(meta, Symbol("#self#"), :ctx, :f, :args)
  forw = varargs!(meta, forw, 3)
  forw = slots!(pis!(inlineable!(forw)))
  @static if VERSION >= v"1.3"  # no edges pre-1.3
    append!(meta.code.edges, cr_edges)  # be ready to swap to using chainrule if one is declared
  end
  return update!(meta.code, forw)
end

@generated function (j::Pullback{T})(Δ) where T
  ignore(T) && return :nothing
  g = try _lookup_grad(T)
  catch e
    rethrow(CompileError(T,e))
  end
  if g == nothing
    Δ == Nothing && return :nothing
    return :(error("Non-differentiable function $(repr(j.t[1]))"))
  end
  meta, _, back = g
  argnames!(meta, Symbol("#self#"), :Δ)
  back = slots!(inlineable!(back))
  return update!(meta.code, back)
end
