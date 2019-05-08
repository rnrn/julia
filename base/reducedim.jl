# This file is a part of Julia. License is MIT: https://julialang.org/license

## Functions to compute the reduced shape

# for reductions that expand 0 dims to 1
reduced_index(i::OneTo) = OneTo(1)
reduced_index(i::Union{Slice, IdentityUnitRange}) = first(i):first(i)
reduced_index(i::AbstractUnitRange) =
    throw(ArgumentError(
"""
No method is implemented for reducing index range of type $typeof(i). Please implement
reduced_index for this index type or report this as an issue.
"""
    ))
reduced_indices(a::AbstractArray, region) = reduced_indices(axes(a), region)

# for reductions that keep 0 dims as 0
reduced_indices0(a::AbstractArray, region) = reduced_indices0(axes(a), region)

function reduced_indices(inds::Indices{N}, d::Int) where N
    d < 1 && throw(ArgumentError("dimension must be ≥ 1, got $d"))
    if d == 1
        return (reduced_index(inds[1]), tail(inds)...)
    elseif 1 < d <= N
        return tuple(inds[1:d-1]..., oftype(inds[d], reduced_index(inds[d])), inds[d+1:N]...)::typeof(inds)
    else
        return inds
    end
end

function reduced_indices0(inds::Indices{N}, d::Int) where N
    d < 1 && throw(ArgumentError("dimension must be ≥ 1, got $d"))
    if d <= N
        ind = inds[d]
        rd = isempty(ind) ? ind : reduced_index(inds[d])
        if d == 1
            return (rd, tail(inds)...)
        else
            return tuple(inds[1:d-1]..., oftype(inds[d], rd), inds[d+1:N]...)::typeof(inds)
        end
    else
        return inds
    end
end

function reduced_indices(inds::Indices{N}, region) where N
    rinds = [inds...]
    for i in region
        isa(i, Integer) || throw(ArgumentError("reduced dimension(s) must be integers"))
        d = Int(i)
        if d < 1
            throw(ArgumentError("region dimension(s) must be ≥ 1, got $d"))
        elseif d <= N
            rinds[d] = reduced_index(rinds[d])
        end
    end
    tuple(rinds...)::typeof(inds)
end

function reduced_indices0(inds::Indices{N}, region) where N
    rinds = [inds...]
    for i in region
        isa(i, Integer) || throw(ArgumentError("reduced dimension(s) must be integers"))
        d = Int(i)
        if d < 1
            throw(ArgumentError("region dimension(s) must be ≥ 1, got $d"))
        elseif d <= N
            rind = rinds[d]
            rinds[d] = isempty(rind) ? rind : reduced_index(rind)
        end
    end
    tuple(rinds...)::typeof(inds)
end

###### Generic reduction functions #####

## initialization
# initarray! is only called by sum!, prod!, etc.
for (Op, initfun) in ((:(typeof(add_sum)), :zero), (:(typeof(mul_prod)), :one))
    @eval initarray!(a::AbstractArray{T}, ::$(Op), init::Bool, src::AbstractArray) where {T} = (init && fill!(a, $(initfun)(T)); a)
end

for Op in (:(typeof(max)), :(typeof(min)))
    @eval initarray!(a::AbstractArray{T}, ::$(Op), init::Bool, src::AbstractArray) where {T} = (init && copyfirst!(a, src); a)
end

for (Op, initval) in ((:(typeof(&)), true), (:(typeof(|)), false))
    @eval initarray!(a::AbstractArray, ::$(Op), init::Bool, src::AbstractArray) = (init && fill!(a, $initval); a)
end

# reducedim_initarray is called by
reducedim_initarray(A::AbstractArray, region, init, ::Type{R}) where {R} = fill!(similar(A,R,reduced_indices(A,region)), init)
reducedim_initarray(A::AbstractArray, region, init::T) where {T} = reducedim_initarray(A, region, init, T)

# TODO: better way to handle reducedim initialization
#
# The current scheme is basically following Steven G. Johnson's original implementation
#
promote_union(T::Union) = promote_type(promote_union(T.a), promote_union(T.b))
promote_union(T) = T

_realtype(::Type{<:Complex}) = Real
_realtype(::Type{Complex{T}}) where T<:Real = T
_realtype(T::Type) = T
_realtype(::Union{typeof(abs),typeof(abs2)}, T) = _realtype(T)
_realtype(::Any, T) = T

function reducedim_init(f, op::Union{typeof(+),typeof(add_sum)}, A::AbstractArray, region)
    _reducedim_init(f, op, zero, sum, A, region)
end
function reducedim_init(f, op::Union{typeof(*),typeof(mul_prod)}, A::AbstractArray, region)
    _reducedim_init(f, op, one, prod, A, region)
end
function _reducedim_init(f, op, fv, fop, A, region)
    T = _realtype(f, promote_union(eltype(A)))
    if T !== Any && applicable(zero, T)
        x = f(zero(T))
        z = op(fv(x), fv(x))
        Tr = z isa T ? T : typeof(z)
    else
        z = fv(fop(f, A))
        Tr = typeof(z)
    end
    return reducedim_initarray(A, region, z, Tr)
end

# initialization when computing minima and maxima requires a little care
for (f1, f2, initval) in ((:min, :max, :Inf), (:max, :min, :(-Inf)))
    @eval function reducedim_init(f, op::typeof($f1), A::AbstractArray, region)
        # First compute the reduce indices. This will throw an ArgumentError
        # if any region is invalid
        ri = reduced_indices(A, region)

        # Next, throw if reduction is over a region with length zero
        any(i -> isempty(axes(A, i)), region) && _empty_reduce_error()

        # Make a view of the first slice of the region
        A1 = view(A, ri...)

        if isempty(A1)
            # If the slice is empty just return non-view version as the initial array
            return copy(A1)
        else
            # otherwise use the min/max of the first slice as initial value
            v0 = mapreduce(f, $f2, A1)

            # but NaNs need to be avoided as intial values
            v0 = v0 != v0 ? typeof(v0)($initval) : v0

            T = _realtype(f, promote_union(eltype(A)))
            Tr = v0 isa T ? T : typeof(v0)
            return reducedim_initarray(A, region, v0, Tr)
        end
    end
end
reducedim_init(f::Union{typeof(abs),typeof(abs2)}, op::typeof(max), A::AbstractArray{T}, region) where {T} =
    reducedim_initarray(A, region, zero(f(zero(T))), _realtype(f, T))

reducedim_init(f, op::typeof(&), A::AbstractArray, region) = reducedim_initarray(A, region, true)
reducedim_init(f, op::typeof(|), A::AbstractArray, region) = reducedim_initarray(A, region, false)

# specialize to make initialization more efficient for common cases

let
    BitIntFloat = Union{BitInteger, Math.IEEEFloat}
    T = Union{
        [AbstractArray{t} for t in uniontypes(BitIntFloat)]...,
        [AbstractArray{Complex{t}} for t in uniontypes(BitIntFloat)]...}

    global function reducedim_init(f, op::Union{typeof(+),typeof(add_sum)}, A::T, region)
        z = zero(f(zero(eltype(A))))
        reducedim_initarray(A, region, op(z, z))
    end
    global function reducedim_init(f, op::Union{typeof(*),typeof(mul_prod)}, A::T, region)
        u = one(f(one(eltype(A))))
        reducedim_initarray(A, region, op(u, u))
    end
end

## generic (map)reduction

has_fast_linear_indexing(a::AbstractArray) = false
has_fast_linear_indexing(a::Array) = true

function check_reducedims(R, A)
    # Check whether R has compatible dimensions w.r.t. A for reduction
    #
    # It returns an integer value (useful for choosing implementation)
    # - If it reduces only along leading dimensions, e.g. sum(A, dims=1) or sum(A, dims=(1,2)),
    #   it returns the length of the leading slice. For the two examples above,
    #   it will be size(A, 1) or size(A, 1) * size(A, 2).
    # - Otherwise, e.g. sum(A, dims=2) or sum(A, dims=(1,3)), it returns 0.
    #
    ndims(R) <= ndims(A) || throw(DimensionMismatch("cannot reduce $(ndims(A))-dimensional array to $(ndims(R)) dimensions"))
    lsiz = 1
    had_nonreduc = false
    for i = 1:ndims(A)
        Ri, Ai = axes(R, i), axes(A, i)
        sRi, sAi = length(Ri), length(Ai)
        if sRi == 1
            if sAi > 1
                if had_nonreduc
                    lsiz = 0  # to reduce along i, but some previous dimensions were non-reducing
                else
                    lsiz *= sAi  # if lsiz was set to zero, it will stay to be zero
                end
            end
        else
            Ri == Ai || throw(DimensionMismatch("reduction on array with indices $(axes(A)) with output with indices $(axes(R))"))
            had_nonreduc = true
        end
    end
    return lsiz
end

"""
Extract first entry of slices of array A into existing array R.
"""
copyfirst!(R::AbstractArray, A::AbstractArray) = mapfirst!(identity, R, A)

function mapfirst!(f, R::AbstractArray, A::AbstractArray{<:Any,N}) where {N}
    lsiz = check_reducedims(R, A)
    t = _firstreducedslice(axes(R), axes(A))
    map!(f, R, view(A, t...))
end
# We know that the axes of R and A are compatible, but R might have a different number of
# dimensions than A, which is trickier than it seems due to offset arrays and type stability
_firstreducedslice(::Tuple{}, a::Tuple{}) = ()
_firstreducedslice(::Tuple, ::Tuple{}) = ()
@inline _firstreducedslice(::Tuple{}, a::Tuple) = (_firstslice(a[1]), _firstreducedslice((), tail(a))...)
@inline _firstreducedslice(r::Tuple, a::Tuple) = (length(r[1])==1 ? _firstslice(a[1]) : r[1], _firstreducedslice(tail(r), tail(a))...)
_firstslice(i::OneTo) = OneTo(1)
_firstslice(i::Slice) = Slice(_firstslice(i.indices))
_firstslice(i) = i[firstindex(i):firstindex(i)]

function _mapreducedim!(f, op, R::AbstractArray, A::AbstractArray)
    lsiz = check_reducedims(R,A)
    isempty(A) && return R

    if has_fast_linear_indexing(A) && lsiz > 16
        # use mapreduce_impl, which is probably better tuned to achieve higher performance
        nslices = div(length(A), lsiz)
        ibase = first(LinearIndices(A))-1
        for i = 1:nslices
            @inbounds R[i] = op(R[i], mapreduce_impl(f, op, A, ibase+1, ibase+lsiz))
            ibase += lsiz
        end
        return R
    end
    indsAt, indsRt = safe_tail(axes(A)), safe_tail(axes(R)) # handle d=1 manually
    keep, Idefault = Broadcast.shapeindexer(indsRt)
    if reducedim1(R, A)
        # keep the accumulator as a local variable when reducing along the first dimension
        i1 = first(axes1(R))
        @inbounds for IA in CartesianIndices(indsAt)
            IR = Broadcast.newindex(IA, keep, Idefault)
            r = R[i1,IR]
            @simd for i in axes(A, 1)
                r = op(r, f(A[i, IA]))
            end
            R[i1,IR] = r
        end
    else
        @inbounds for IA in CartesianIndices(indsAt)
            IR = Broadcast.newindex(IA, keep, Idefault)
            @simd for i in axes(A, 1)
                R[i,IR] = op(R[i,IR], f(A[i,IA]))
            end
        end
    end
    return R
end

mapreducedim!(f, op, R::AbstractArray, A::AbstractArray) =
    (_mapreducedim!(f, op, R, A); R)

reducedim!(op, R::AbstractArray{RT}, A::AbstractArray) where {RT} =
    mapreducedim!(identity, op, R, A)

"""
    mapreduce(f, op, A::AbstractArray...; dims=:, [init])

Evaluates to the same as `reduce(op, map(f, A); dims=dims, init=init)`, but is generally
faster because the intermediate array is avoided.

!!! compat "Julia 1.2"
    `mapreduce` with multiple iterators requires Julia 1.2 or later.

# Examples
```jldoctest
julia> a = reshape(Vector(1:16), (4,4))
4×4 Array{Int64,2}:
 1  5   9  13
 2  6  10  14
 3  7  11  15
 4  8  12  16

julia> mapreduce(isodd, *, a, dims=1)
1×4 Array{Bool,2}:
 0  0  0  0

julia> mapreduce(isodd, |, a, dims=1)
1×4 Array{Bool,2}:
 1  1  1  1
```
"""
mapreduce(f, op, A::AbstractArray; dims=:, kw...) = _mapreduce_dim(f, op, kw.data, A, dims)
mapreduce(f, op, A::AbstractArray...; kw...) = reduce(op, map(f, A...); kw...)

_mapreduce_dim(f, op, nt::NamedTuple{(:init,)}, A::AbstractArray, ::Colon) = mapfoldl(f, op, A; nt...)

_mapreduce_dim(f, op, ::NamedTuple{()}, A::AbstractArray, ::Colon) = _mapreduce(f, op, IndexStyle(A), A)

_mapreduce_dim(f, op, nt::NamedTuple{(:init,)}, A::AbstractArray, dims) =
    mapreducedim!(f, op, reducedim_initarray(A, dims, nt.init), A)

_mapreduce_dim(f, op, ::NamedTuple{()}, A::AbstractArray, dims) =
    mapreducedim!(f, op, reducedim_init(f, op, A, dims), A)

"""
    reduce(f, A; dims=:, [init])

Reduce 2-argument function `f` along dimensions of `A`. `dims` is a vector specifying the
dimensions to reduce, and the keyword argument `init` is the initial value to use in the
reductions. For `+`, `*`, `max` and `min` the `init` argument is optional.

The associativity of the reduction is implementation-dependent; if you need a particular
associativity, e.g. left-to-right, you should write your own loop or consider using
[`foldl`](@ref) or [`foldr`](@ref). See documentation for [`reduce`](@ref).

# Examples
```jldoctest
julia> a = reshape(Vector(1:16), (4,4))
4×4 Array{Int64,2}:
 1  5   9  13
 2  6  10  14
 3  7  11  15
 4  8  12  16

julia> reduce(max, a, dims=2)
4×1 Array{Int64,2}:
 13
 14
 15
 16

julia> reduce(max, a, dims=1)
1×4 Array{Int64,2}:
 4  8  12  16
```
"""
reduce(op, A::AbstractArray; kw...) = mapreduce(identity, op, A; kw...)

##### Specific reduction functions #####
"""
    sum(A::AbstractArray; dims)

Sum elements of an array over the given dimensions.

# Examples
```jldoctest
julia> A = [1 2; 3 4]
2×2 Array{Int64,2}:
 1  2
 3  4

julia> sum(A, dims=1)
1×2 Array{Int64,2}:
 4  6

julia> sum(A, dims=2)
2×1 Array{Int64,2}:
 3
 7
```
"""
sum(A::AbstractArray; dims)

"""
    sum!(r, A)

Sum elements of `A` over the singleton dimensions of `r`, and write results to `r`.

# Examples
```jldoctest
julia> A = [1 2; 3 4]
2×2 Array{Int64,2}:
 1  2
 3  4

julia> sum!([1; 1], A)
2-element Array{Int64,1}:
 3
 7

julia> sum!([1 1], A)
1×2 Array{Int64,2}:
 4  6
```
"""
sum!(r, A)

"""
    prod(A::AbstractArray; dims)

Multiply elements of an array over the given dimensions.

# Examples
```jldoctest
julia> A = [1 2; 3 4]
2×2 Array{Int64,2}:
 1  2
 3  4

julia> prod(A, dims=1)
1×2 Array{Int64,2}:
 3  8

julia> prod(A, dims=2)
2×1 Array{Int64,2}:
  2
 12
```
"""
prod(A::AbstractArray; dims)

"""
    prod!(r, A)

Multiply elements of `A` over the singleton dimensions of `r`, and write results to `r`.

# Examples
```jldoctest
julia> A = [1 2; 3 4]
2×2 Array{Int64,2}:
 1  2
 3  4

julia> prod!([1; 1], A)
2-element Array{Int64,1}:
  2
 12

julia> prod!([1 1], A)
1×2 Array{Int64,2}:
 3  8
```
"""
prod!(r, A)

"""
    maximum(A::AbstractArray; dims)

Compute the maximum value of an array over the given dimensions. See also the
[`max(a,b)`](@ref) function to take the maximum of two or more arguments,
which can be applied elementwise to arrays via `max.(a,b)`.

# Examples
```jldoctest
julia> A = [1 2; 3 4]
2×2 Array{Int64,2}:
 1  2
 3  4

julia> maximum(A, dims=1)
1×2 Array{Int64,2}:
 3  4

julia> maximum(A, dims=2)
2×1 Array{Int64,2}:
 2
 4
```
"""
maximum(A::AbstractArray; dims)

"""
    maximum!(r, A)

Compute the maximum value of `A` over the singleton dimensions of `r`, and write results to `r`.

# Examples
```jldoctest
julia> A = [1 2; 3 4]
2×2 Array{Int64,2}:
 1  2
 3  4

julia> maximum!([1; 1], A)
2-element Array{Int64,1}:
 2
 4

julia> maximum!([1 1], A)
1×2 Array{Int64,2}:
 3  4
```
"""
maximum!(r, A)

"""
    minimum(A::AbstractArray; dims)

Compute the minimum value of an array over the given dimensions. See also the
[`min(a,b)`](@ref) function to take the minimum of two or more arguments,
which can be applied elementwise to arrays via `min.(a,b)`.

# Examples
```jldoctest
julia> A = [1 2; 3 4]
2×2 Array{Int64,2}:
 1  2
 3  4

julia> minimum(A, dims=1)
1×2 Array{Int64,2}:
 1  2

julia> minimum(A, dims=2)
2×1 Array{Int64,2}:
 1
 3
```
"""
minimum(A::AbstractArray; dims)

"""
    minimum!(r, A)

Compute the minimum value of `A` over the singleton dimensions of `r`, and write results to `r`.

# Examples
```jldoctest
julia> A = [1 2; 3 4]
2×2 Array{Int64,2}:
 1  2
 3  4

julia> minimum!([1; 1], A)
2-element Array{Int64,1}:
 1
 3

julia> minimum!([1 1], A)
1×2 Array{Int64,2}:
 1  2
```
"""
minimum!(r, A)

"""
    all(A; dims)

Test whether all values along the given dimensions of an array are `true`.

# Examples
```jldoctest
julia> A = [true false; true true]
2×2 Array{Bool,2}:
 1  0
 1  1

julia> all(A, dims=1)
1×2 Array{Bool,2}:
 1  0

julia> all(A, dims=2)
2×1 Array{Bool,2}:
 0
 1
```
"""
all(A::AbstractArray; dims)

"""
    all!(r, A)

Test whether all values in `A` along the singleton dimensions of `r` are `true`, and write results to `r`.

# Examples
```jldoctest
julia> A = [true false; true false]
2×2 Array{Bool,2}:
 1  0
 1  0

julia> all!([1; 1], A)
2-element Array{Int64,1}:
 0
 0

julia> all!([1 1], A)
1×2 Array{Int64,2}:
 1  0
```
"""
all!(r, A)

"""
    any(A; dims)

Test whether any values along the given dimensions of an array are `true`.

# Examples
```jldoctest
julia> A = [true false; true false]
2×2 Array{Bool,2}:
 1  0
 1  0

julia> any(A, dims=1)
1×2 Array{Bool,2}:
 1  0

julia> any(A, dims=2)
2×1 Array{Bool,2}:
 1
 1
```
"""
any(::AbstractArray; dims)

"""
    any!(r, A)

Test whether any values in `A` along the singleton dimensions of `r` are `true`, and write
results to `r`.

# Examples
```jldoctest
julia> A = [true false; true false]
2×2 Array{Bool,2}:
 1  0
 1  0

julia> any!([1; 1], A)
2-element Array{Int64,1}:
 1
 1

julia> any!([1 1], A)
1×2 Array{Int64,2}:
 1  0
```
"""
any!(r, A)

for (fname, _fname, op) in [(:prod,    :_prod,    :mul_prod),
                            (:maximum, :_maximum, :max),     (:minimum, :_minimum, :min)]
    @eval begin
        # User-facing methods with keyword arguments
        @inline ($fname)(a::AbstractArray; dims=:) = ($_fname)(a, dims)
        @inline ($fname)(f, a::AbstractArray; dims=:) = ($_fname)(f, a, dims)

        # Underlying implementations using dispatch
        ($_fname)(a, ::Colon) = ($_fname)(identity, a, :)
        ($_fname)(f, a, ::Colon) = mapreduce(f, $op, a)
    end
end

# Sum is the only reduction which supports weights
sum(a::AbstractArray; dims=:, weights::Union{AbstractArray,Nothing}=nothing) =
    _sum(a, dims, weights)
sum(f, a::AbstractArray; dims=:, weights::Union{AbstractArray,Nothing}=nothing) =
    _sum(f, a, dims, weights)
sum(a, ::Colon, weights) = _sum(identity, a, :, weights)
sum(f, a, ::Colon, ::Nothing) = mapreduce(f, add_sum, a)

any(a::AbstractArray; dims=:)              = _any(a, dims)
any(f::Function, a::AbstractArray; dims=:) = _any(f, a, dims)
_any(a, ::Colon)                           = _any(identity, a, :)
all(a::AbstractArray; dims=:)              = _all(a, dims)
all(f::Function, a::AbstractArray; dims=:) = _all(f, a, dims)
_all(a, ::Colon)                           = _all(identity, a, :)

for (fname, op) in [(:prod, :mul_prod),
                    (:maximum, :max), (:minimum, :min),
                    (:all, :&),       (:any, :|)]
    fname! = Symbol(fname, '!')
    _fname! = Symbol('_', fname, '!')
    _fname = Symbol('_', fname)
    @eval begin
        $(fname!)(r::AbstractArray, A::AbstractArray; init::Bool=true) =
            $(fname!)(identity, r, A; init=init)
        $(fname!)(f::Function, r::AbstractArray, A::AbstractArray; init::Bool=true) =
            $(_fname!)(f, r, A; init=init)

        # Underlying implementations using dispatch
        $(_fname!)(f, r::AbstractArray, A::AbstractArray; init::Bool=true) =
            mapreducedim!(f, $(op), initarray!(r, $(op), init, A), A)
        $(_fname)(A, dims) = $(_fname)(identity, A, dims)
        $(_fname)(f, A, dims) = mapreduce(f, $(op), A, dims=dims)
    end
end

# Sum is the only reduction which supports weights
sum!(r::AbstractArray, A::AbstractArray;
     init::Bool=true, weights::Union{AbstractArray,Nothing}=nothing) =
    sum!(identity, r, A; init=init, weights=weights)
sum!(f::Function, r::AbstractArray, A::AbstractArray;
     init::Bool=true, weights::Union{AbstractArray,Nothing}=nothing) =
    _sum!(f, r, A, weights; init=init)
_sum!(f, r::AbstractArray, A::AbstractArray, ::Nothing; init::Bool=true) =
    mapreducedim!(f, add_sum, initarray!(r, add_sum, init, A), A)
_sum(A, dims, weights) = _sum(identity, A, dims, weights)
_sum(f, A, dims, ::Nothing) = mapreduce(f, add_sum, A, dims=dims)


# Weighted sum
function _sum(A::AbstractArray, dims::Colon, w::AbstractArray{<:Real})
    sw = size(w)
    sA = size(A)
    if sw != sA
        throw(DimensionMismatch("weights must have the same dimension as data (got $sw and $sA)."))
    end
    s0 = zero(eltype(A)) * zero(eltype(w))
    s = add_sum(s0, s0)
    @inbounds @simd for i in eachindex(A, w)
        s += A[i] * w[i]
    end
    s
end

# Weighted sum over dimensions
#
#  Brief explanation of the algorithm:
#  ------------------------------------
#
#  1. _wsum! provides the core implementation, which assumes that
#     the dimensions of all input arguments are consistent, and no
#     dimension checking is performed therein.
#
#     wsum and wsum! perform argument checking and call _wsum!
#     internally.
#
#  2. _wsum! adopt a Cartesian based implementation for general
#     sub types of AbstractArray. Particularly, a faster routine
#     that keeps a local accumulator will be used when dim = 1.
#
#     The internal function that implements this is _wsum_general!
#
#  3. _wsum! is specialized for following cases:
#     (a) A is a vector: we invoke the vector version wsum above.
#         The internal function that implements this is _wsum1!
#
#     (b) A is a dense matrix with eltype <: BlasReal: we call gemv!
#         The internal function that implements this is _wsum2_blas!
#         (in LinearAlgebra/src/wsum.jl)
#
#     (c) A is a contiguous array with eltype <: BlasReal:
#         dim == 1: treat A like a matrix of size (d1, d2 x ... x dN)
#         dim == N: treat A like a matrix of size (d1 x ... x d(N-1), dN)
#         otherwise: decompose A into multiple pages, and apply _wsum2_blas!
#         for each
#         The internal function that implements this is _wsumN!
#         (in LinearAlgebra/src/wsum.jl)
#
#     (d) A is a general dense array with eltype <: BlasReal:
#         dim <= 2: delegate to (a) and (b)
#         otherwise, decompose A into multiple pages
#         The internal function that implements this is _wsumN!
#         (in LinearAlgebra/src/wsum.jl)

function _wsum1!(R::AbstractArray, A::AbstractVector, w::AbstractVector, init::Bool)
    r = _sum(A, :, w)
    if init
        R[1] = r
    else
        R[1] += r
    end
    return R
end

function _wsum_general!(R::AbstractArray{S}, A::AbstractArray, w::AbstractVector,
                        dim::Int, init::Bool) where {S}
    # following the implementation of _mapreducedim!
    lsiz = check_reducedims(R,A)
    !isempty(R) && init && fill!(R, zero(S))
    isempty(A) && return R

    indsAt, indsRt = safe_tail(axes(A)), safe_tail(axes(R)) # handle d=1 manually
    keep, Idefault = Broadcast.shapeindexer(indsRt)
    if reducedim1(R, A)
        i1 = first(axes1(R))
        for IA in CartesianIndices(indsAt)
            IR = Broadcast.newindex(IA, keep, Idefault)
            r = R[i1,IR]
            @simd for i in axes(A, 1)
                r += A[i,IA] * w[dim > 1 ? IA[dim-1] : i]
            end
            R[i1,IR] = r
        end
    else
        for IA in CartesianIndices(indsAt)
            IR = Broadcast.newindex(IA, keep, Idefault)
            @simd for i in axes(A, 1)
                R[i,IR] += A[i,IA] * w[dim > 1 ? IA[dim-1] : i]
            end
        end
    end
    return R
end

_wsum!(R::AbstractArray, A::AbstractVector, w::AbstractVector,
       dim::Int, init::Bool) =
    _wsum1!(R, A, w, init)

_wsum!(R::AbstractArray, A::AbstractArray, w::AbstractVector,
       dim::Int, init::Bool) =
    _wsum_general!(R, A, w, dim, init)

function _sum!(::typeof(identity), R::AbstractArray, A::AbstractArray{T,N}, w::AbstractVector;
               init::Bool=true) where {T,N}
    check_reducedims(R,A)
    reddims = size(R) .!= size(A)
    dim = something(findfirst(reddims), ndims(R)+1)
    if findnext(reddims, dim+1) !== nothing
        throw(ArgumentError("reducing over more than one dimension is not supported with weights"))
    end
    lw = length(w)
    ldim = size(A, dim)
    if lw != ldim
        throw(DimensionMismatch("weights must have the same length as the dimension " *
                                "over which reduction is performed (got $lw and $ldim)."))
    end
    _wsum!(R, A, w, dim, init)
end

_sum(A::AbstractArray, dims, w::AbstractArray) =
    _sum!(identity, reducedim_init(t -> t*zero(eltype(w)), add_sum, A, dims), A, w)

##### findmin & findmax #####
# The initial values of Rval are not used if the corresponding indices in Rind are 0.
#
function findminmax!(f, Rval, Rind, A::AbstractArray{T,N}) where {T,N}
    (isempty(Rval) || isempty(A)) && return Rval, Rind
    lsiz = check_reducedims(Rval, A)
    for i = 1:N
        axes(Rval, i) == axes(Rind, i) || throw(DimensionMismatch("Find-reduction: outputs must have the same indices"))
    end
    # If we're reducing along dimension 1, for efficiency we can make use of a temporary.
    # Otherwise, keep the result in Rval/Rind so that we traverse A in storage order.
    indsAt, indsRt = safe_tail(axes(A)), safe_tail(axes(Rval))
    keep, Idefault = Broadcast.shapeindexer(indsRt)
    ks = keys(A)
    y = iterate(ks)
    zi = zero(eltype(ks))
    if reducedim1(Rval, A)
        i1 = first(axes1(Rval))
        @inbounds for IA in CartesianIndices(indsAt)
            IR = Broadcast.newindex(IA, keep, Idefault)
            tmpRv = Rval[i1,IR]
            tmpRi = Rind[i1,IR]
            for i in axes(A,1)
                k, kss = y::Tuple
                tmpAv = A[i,IA]
                if tmpRi == zi || (tmpRv == tmpRv && (tmpAv != tmpAv || f(tmpAv, tmpRv)))
                    tmpRv = tmpAv
                    tmpRi = k
                end
                y = iterate(ks, kss)
            end
            Rval[i1,IR] = tmpRv
            Rind[i1,IR] = tmpRi
        end
    else
        @inbounds for IA in CartesianIndices(indsAt)
            IR = Broadcast.newindex(IA, keep, Idefault)
            for i in axes(A, 1)
                k, kss = y::Tuple
                tmpAv = A[i,IA]
                tmpRv = Rval[i,IR]
                tmpRi = Rind[i,IR]
                if tmpRi == zi || (tmpRv == tmpRv && (tmpAv != tmpAv || f(tmpAv, tmpRv)))
                    Rval[i,IR] = tmpAv
                    Rind[i,IR] = k
                end
                y = iterate(ks, kss)
            end
        end
    end
    Rval, Rind
end

"""
    findmin!(rval, rind, A) -> (minval, index)

Find the minimum of `A` and the corresponding linear index along singleton
dimensions of `rval` and `rind`, and store the results in `rval` and `rind`.
`NaN` is treated as less than all other values.
"""
function findmin!(rval::AbstractArray, rind::AbstractArray, A::AbstractArray;
                  init::Bool=true)
    findminmax!(isless, init && !isempty(A) ? fill!(rval, first(A)) : rval, fill!(rind,zero(eltype(keys(A)))), A)
end

"""
    findmin(A; dims) -> (minval, index)

For an array input, returns the value and index of the minimum over the given dimensions.
`NaN` is treated as less than all other values.

# Examples
```jldoctest
julia> A = [1.0 2; 3 4]
2×2 Array{Float64,2}:
 1.0  2.0
 3.0  4.0

julia> findmin(A, dims=1)
([1.0 2.0], CartesianIndex{2}[CartesianIndex(1, 1) CartesianIndex(1, 2)])

julia> findmin(A, dims=2)
([1.0; 3.0], CartesianIndex{2}[CartesianIndex(1, 1); CartesianIndex(2, 1)])
```
"""
findmin(A::AbstractArray; dims=:) = _findmin(A, dims)

function _findmin(A, region)
    ri = reduced_indices0(A, region)
    if isempty(A)
        if prod(map(length, reduced_indices(A, region))) != 0
            throw(ArgumentError("collection slices must be non-empty"))
        end
        (similar(A, ri), zeros(eltype(keys(A)), ri))
    else
        findminmax!(isless, fill!(similar(A, ri), first(A)),
                    zeros(eltype(keys(A)), ri), A)
    end
end

isgreater(a, b) = isless(b,a)

"""
    findmax!(rval, rind, A) -> (maxval, index)

Find the maximum of `A` and the corresponding linear index along singleton
dimensions of `rval` and `rind`, and store the results in `rval` and `rind`.
`NaN` is treated as greater than all other values.
"""
function findmax!(rval::AbstractArray, rind::AbstractArray, A::AbstractArray;
                  init::Bool=true)
    findminmax!(isgreater, init && !isempty(A) ? fill!(rval, first(A)) : rval, fill!(rind,zero(eltype(keys(A)))), A)
end

"""
    findmax(A; dims) -> (maxval, index)

For an array input, returns the value and index of the maximum over the given dimensions.
`NaN` is treated as greater than all other values.

# Examples
```jldoctest
julia> A = [1.0 2; 3 4]
2×2 Array{Float64,2}:
 1.0  2.0
 3.0  4.0

julia> findmax(A, dims=1)
([3.0 4.0], CartesianIndex{2}[CartesianIndex(2, 1) CartesianIndex(2, 2)])

julia> findmax(A, dims=2)
([2.0; 4.0], CartesianIndex{2}[CartesianIndex(1, 2); CartesianIndex(2, 2)])
```
"""
findmax(A::AbstractArray; dims=:) = _findmax(A, dims)

function _findmax(A, region)
    ri = reduced_indices0(A, region)
    if isempty(A)
        if prod(map(length, reduced_indices(A, region))) != 0
            throw(ArgumentError("collection slices must be non-empty"))
        end
        similar(A, ri), zeros(eltype(keys(A)), ri)
    else
        findminmax!(isgreater, fill!(similar(A, ri), first(A)),
                    zeros(eltype(keys(A)), ri), A)
    end
end

reducedim1(R, A) = length(axes1(R)) == 1

"""
    argmin(A; dims) -> indices

For an array input, return the indices of the minimum elements over the given dimensions.
`NaN` is treated as less than all other values.

# Examples
```jldoctest
julia> A = [1.0 2; 3 4]
2×2 Array{Float64,2}:
 1.0  2.0
 3.0  4.0

julia> argmin(A, dims=1)
1×2 Array{CartesianIndex{2},2}:
 CartesianIndex(1, 1)  CartesianIndex(1, 2)

julia> argmin(A, dims=2)
2×1 Array{CartesianIndex{2},2}:
 CartesianIndex(1, 1)
 CartesianIndex(2, 1)
```
"""
argmin(A::AbstractArray; dims=:) = findmin(A; dims=dims)[2]

"""
    argmax(A; dims) -> indices

For an array input, return the indices of the maximum elements over the given dimensions.
`NaN` is treated as greater than all other values.

# Examples
```jldoctest
julia> A = [1.0 2; 3 4]
2×2 Array{Float64,2}:
 1.0  2.0
 3.0  4.0

julia> argmax(A, dims=1)
1×2 Array{CartesianIndex{2},2}:
 CartesianIndex(2, 1)  CartesianIndex(2, 2)

julia> argmax(A, dims=2)
2×1 Array{CartesianIndex{2},2}:
 CartesianIndex(1, 2)
 CartesianIndex(2, 2)
```
"""
argmax(A::AbstractArray; dims=:) = findmax(A; dims=dims)[2]