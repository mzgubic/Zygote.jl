using Base: RefValue

# Interfaces

accum() = nothing
accum(x) = x

accum(x, y) =
  x === nothing ? y :
  y === nothing ? x :
  x + y

accum(x, y, zs...) = accum(accum(x, y), zs...)

accum(x::Tuple, y::Tuple) = accum.(x, y)
accum(x::AbstractArray, y::AbstractArray) = accum.(x, y)

@generated function accum(x::NamedTuple, y::NamedTuple)
  grad(x) = x in fieldnames(y) ? :(y.$x) : :nothing
  Expr(:tuple, [:($f=accum(x.$f, $(grad(f)))) for f in fieldnames(x)]...)
end

function accum(x::RefValue, y::RefValue)
  @assert x === y
  return x
end

# Core functions
@nograd eps, Base.eval, Core.TypeVar, Core.UnionAll

@adjoint deepcopy(x) = deepcopy(x), ȳ -> (ȳ,)

@adjoint (::Type{V})(x...) where V<:Val = V(x...), _ -> DoesNotExist()

@adjoint ifelse(cond::Bool, t, f) =
  ifelse(cond, t, f),
  Δ -> cond ? (DoesNotExist(), Δ, zero(Δ)) : (DoesNotExist(), zero(Δ), Δ)

@adjoint Base.typeassert(x, T) = Base.typeassert(x, T), Δ -> (Δ, DoesNotExist())

@generated function accum_param(cx::Context, x, Δ)
  isbitstype(x) && return :(Δ)
  quote
    if haskey(cache(cx), x)
      cache(cx)[x] = accum(cache(cx)[x],Δ)
      return
    else
      return Δ
    end
  end
end

function accum_global(cx::Context, ref, x̄)
  (x̄ isa AbstractZero || isconst(ref.mod, ref.name)) && return Zero()
  gs = cache(cx)
  gs[ref] = accum(get(gs, ref, Zero()), x̄)
  return
end

unwrap(x) = x

@adjoint unwrap(x) = unwrap(x), x̄ -> (accum_param(__context__, x, x̄),)

unwrap(ref, x) = x

@adjoint unwrap(ref, x) = unwrap(x), function (x̄)
  accum_global(__context__, ref, x̄)
  (accum_param(__context__, x, x̄),)
end

function global_set(ref, val)
  ccall(:jl_set_global, Cvoid, (Any, Any, Any),
        ref.mod, ref.name, val)
end

@adjoint! function global_set(ref, x)
  global_set(ref, x), function (x̄)
    gs = cache(__context__)
    x̄ = accum(get(gs, ref, Zero()), x̄)
    gs[ref] = Zero()
    return (Zero(), x̄)
  end
end

# Tuples

using Base: tail

@adjoint tuple(xs...) = xs, identity

@adjoint function literal_getindex(xs::NTuple{N,Any}, ::Val{i}) where {N,i}
  val = xs[i]
  function back(Δ)
    accum_param(__context__, val, Δ) isa AbstractZero && return DoesNotExist()
    return ntuple(j -> i == j ? Δ : Zero(), Val(N)), DoesNotExist()
  end
  val, back
end

@adjoint function getindex(xs::NTuple{N,Any}, i::Integer) where N
  val = xs[i]
  function back(Δ)
    accum_param(__context__, val, Δ) isa AbstractZero && return DoesNotExist()
    return ntuple(j -> i == j ? Δ : Zero(), Val(N)), DoesNotExist()
  end
  return val, back
end

@adjoint getindex(xs::NTuple{N,Any}, r::AbstractUnitRange) where N =
  (xs[r], Δ -> (ntuple(j -> j in r ? Δ[findfirst(isequal(j), r)] : Zero(), Val(N)), DoesNotExist()))

function _pullback(cx::Context, ::typeof(literal_indexed_iterate), xs::Tuple, ::Val{i}) where i
  y, b = _pullback(cx, literal_getindex, xs, Val(i))
  back(::Nothing) = nothing # TODO: check what to do
  back(ȳ) = b(ȳ[1])
  (y, i+1), back
end

function _pullback(cx::Context, ::typeof(literal_indexed_iterate), xs::Tuple, ::Val{i}, st) where i
  y, b = _pullback(cx, literal_getindex, xs, Val(i))
  back(::Nothing) = nothing # TODO: check what to do
  back(ȳ) = (b(ȳ[1])..., nothing) # TODO: check what to do
  (y, i+1), back
end

# Needed for iteration lowering
@adjoint Core.getfield(xs::NTuple{N,Any}, i::Integer) where N =
  (xs[i], Δ -> (ntuple(j -> i == j ? Δ : Zero(), Val(N)), DoesNotExist()))

@adjoint Core.getfield(xs::NamedTuple{K,<:NTuple{N,Any}}, i::Integer) where {K,N} =
  (xs[i], Δ -> (NamedTuple{K}(ntuple(j -> i == j ? Δ : Zero(), Val(N))), DoesNotExist()))

@adjoint function Base.first(xs::Tuple)
  drest = map(_->Zero(), tail(xs))
  first(xs), Δ -> ((Δ, drest...),)
end

@adjoint Base.tail(xs::Tuple) = tail(xs), x̄s -> ((Zero(), x̄s...),)

_empty(x) = length(x)
_empty(x::Union{Tuple,NamedTuple}) = map(_->Zero(), x)

_unapply(t::Integer, xs) = xs[1:t], xs[t+1:end]
_unapply(t, xs) = first(xs), tail(xs)
_unapply(t::Tuple{}, xs) = (), xs

function _unapply(t::Tuple, xs)
  t1, xs1 = _unapply(first(t), xs)
  t2, xs2 = _unapply(tail(t), xs1)
  (t1, t2...), xs2
end

function _unapply(t::NamedTuple{K}, xs) where K
  t, rst = _unapply(Tuple(t), xs)
  NamedTuple{K}(t), rst
end

unapply(t, xs) = _unapply(t, xs)[1]

@adjoint! function Core._apply(f, args...)
  y, back = Core._apply(_pullback, (__context__, f), args...)
  st = map(_empty, args)
  y, function (Δ)
    Δ = back(Δ)
    Δ isa AbstractZero ? Zero() :
      (first(Δ), unapply(st, Base.tail(Δ))...)
  end
end

if VERSION >= v"1.4.0-DEV.304"
  @adjoint! function Core._apply_iterate(::typeof(iterate), f, args...)
    y, back = Core._apply(_pullback, (__context__, f), args...)
    st = map(_empty, args)
    y, function (Δ)
      Δ = back(Δ)
      Δ isa AbstractZero ? Zero() :
        (Zero(), first(Δ), unapply(st, Base.tail(Δ))...)
    end
  end
end

# Structs

deref!(x) = x

function deref!(x::Ref)
  d = x[]
  x[] = nothing # TODO: wat dis
  return d
end

@generated nt_zero(x) = Expr(:tuple, [:($f=Zero()) for f in fieldnames(x)]...)

@generated pair(::Val{k}, v) where k = :($k = v,)

@adjoint function literal_getproperty(x, ::Val{f}) where f
  val = getproperty(x, f)
  function back(Δ)
    accum_param(__context__, val, Δ) isa AbstractZero && return DoesNotExist()
    if isimmutable(x)
      ((;nt_zero(x)...,pair(Val(f), Δ)...), DoesNotExist())
    else
      dx = grad_mut(__context__, x)
      dx[] = (;dx[]...,pair(Val(f),accum(getfield(dx[], f), Δ))...)
      return (dx, DoesNotExist())
    end
  end
  unwrap(val), back
end

_pullback(cx::Context, ::typeof(getproperty), x, f::Symbol) =
  _pullback(cx, literal_getproperty, x, Val(f))

_pullback(cx::Context, ::typeof(getfield), x, f::Symbol) =
  _pullback(cx, literal_getproperty, x, Val(f))

_pullback(cx::Context, ::typeof(literal_getindex), x::NamedTuple, ::Val{f}) where f =
  _pullback(cx, literal_getproperty, x, Val(f))

_pullback(cx::Context, ::typeof(literal_getproperty), x::Tuple, ::Val{f}) where f =
  _pullback(cx, literal_getindex, x, Val(f))

grad_mut(x) = Ref{Any}(nt_zero(x))

function grad_mut(cx::Context, x)
  ch = cache(cx)
  if haskey(ch, x)
    ch[x]
  else
    ch[x] = grad_mut(x)
  end
end

@adjoint! function setfield!(x, f, val)
  y = setfield!(x, f, val)
  g = grad_mut(__context__, x)
  y, function (_)
    Δ = getfield(g[], f)
    g[] = (;g[]..., pair(Val(f), Zero())...)
    (Zero(), DoesNotExist(), Δ)
  end
end

struct Jnew{T,G,splat}
  g::G
end

Jnew{T}(g) where T = Jnew{T,typeof(g)}(g)

@adjoint! function __new__(T, args...)
  x = __new__(T, args...)
  g = !T.mutable || fieldcount(T) == 0 ? nothing : grad_mut(__context__, x) # TODO: not sure about this
  x, Jnew{T,typeof(g),false}(g)
end

@adjoint! function __splatnew__(T, args)
  x = __splatnew__(T, args)
  g = !T.mutable || fieldcount(T) == 0 ? nothing : grad_mut(__context__, x) # TODO: not sure about this
  x, Jnew{T,typeof(g),true}(g)
end

# TODO captured mutables + multiple calls to `back`
@generated function (back::Jnew{T,G,false})(Δ::Union{NamedTuple,Nothing,RefValue}) where {T,G} # TODO 
  !T.mutable && Δ == Nothing && return :nothing
  Δ = G == Nothing ? :Δ :
      Δ <: RefValue ? :(back.g[]) :
      :(accum(back.g[], Δ))
  quote
    x̄ = $Δ
    $(G == Nothing || :(back.g[] = nt_zero($Δ)))
    (nothing, $(map(f -> :(x̄.$f), fieldnames(T))...))
  end
end

@generated function (back::Jnew{T,G,true})(Δ::Union{NamedTuple,Nothing,RefValue}) where {T,G} # TODO 
  !T.mutable && Δ == Nothing && return :nothing
  Δ = G == Nothing ? :Δ : :(back.g)
  quote
    x̄ = $Δ
    $(G == Nothing || :($Δ = nt_zero($Δ)))
    (nothing, ($(map(f -> :(x̄.$f), fieldnames(T))...),))
  end
end

(back::Jnew{T})(Δ) where T = error("Need an adjoint for constructor $T. Gradient is of type $(typeof(Δ))")
