# Arnoldi/Lanczos iteration algorithms (with custom IOP)

#######################################
# Output type/cache
"""
    KrylovSubspace{T}(n,[maxiter=30]) -> Ks

Constructs an uninitialized Krylov subspace, which can be filled by `arnoldi!`.

The dimension of the subspace, `Ks.m`, can be dynamically altered but should
be smaller than `maxiter`, the maximum allowed arnoldi iterations.

    getV(Ks) -> V
    getH(Ks) -> H

Access methods for the (extended) orthonormal basis `V` and the (extended)
Gram-Schmidt coefficients `H`. Both methods return a view into the storage
arrays and has the correct dimensions as indicated by `Ks.m`.

    resize!(Ks, maxiter) -> Ks

Resize `Ks` to a different `maxiter`, destroying its contents.

This is an expensive operation and should be used scarcely.
"""
mutable struct KrylovSubspace{B, T, U}
    m::Int        # subspace dimension
    maxiter::Int  # maximum allowed subspace size
    beta::B       # norm(b,2)
    V::Matrix{T}  # orthonormal bases
    H::Matrix{U}  # Gram-Schmidt coefficients (real for Hermitian matrices)
    KrylovSubspace{T,U}(n::Integer, maxiter::Integer=30) where {T,U} = new{real(T), T, U}(
        maxiter, maxiter, zero(real(T)), Matrix{T}(undef, n, maxiter + 1),
        fill(zero(U), maxiter + 1, maxiter))
    KrylovSubspace{T}(n::Integer, maxiter::Integer=30) where {T} = KrylovSubspace{T,T}(n, maxiter)
end
getH(Ks::KrylovSubspace) = @view(Ks.H[1:Ks.m + 1, 1:Ks.m])
getV(Ks::KrylovSubspace) = @view(Ks.V[:, 1:Ks.m + 1])
function Base.resize!(Ks::KrylovSubspace{B,T,U}, maxiter::Integer) where {B,T,U}
    V = Matrix{T}(undef, size(Ks.V, 1), maxiter + 1)
    H = fill(zero(U), maxiter + 1, maxiter)
    Ks.V = V; Ks.H = H
    Ks.m = Ks.maxiter = maxiter
    return Ks
end
function Base.show(io::IO, Ks::KrylovSubspace)
    println(io, "$(Ks.m)-dimensional Krylov subspace with fields")
    println(io, "beta: $(Ks.beta)")
    print(io, "V: ")
    println(IOContext(io, :limit => true), getV(Ks))
    print(io, "H: ")
    println(IOContext(io, :limit => true), getH(Ks))
end

coeff(::Type{T},α::T) where {T} = α
coeff(::Type{U},α::T) where {U<:Real,T<:Complex} = real(α)

#######################################
# Arnoldi/Lanczos with custom IOP
"""
    arnoldi(A,b[;m,tol,opnorm,iop,cache]) -> Ks

Performs `m` anoldi iterations to obtain the Krylov subspace K_m(A,b).

The n x (m + 1) basis vectors `getV(Ks)` and the (m + 1) x m upper Hessenberg
matrix `getH(Ks)` are related by the recurrence formula

```
v_1=b,\\quad Av_j = \\sum_{i=1}^{j+1}h_{ij}v_i\\quad(j = 1,2,\\ldots,m)
```

`iop` determines the length of the incomplete orthogonalization procedure [^1].
The default value of 0 indicates full Arnoldi. For symmetric/Hermitian `A`,
`iop` will be ignored and the Lanczos algorithm will be used instead.

Refer to `KrylovSubspace` for more information regarding the output.

Happy-breakdown occurs whenver `norm(v_j) < tol * opnorm(A, Inf)`, in this case
the dimension of `Ks` is smaller than `m`.

[^1]: Koskela, A. (2015). Approximating the matrix exponential of an
advection-diffusion operator using the incomplete orthogonalization method. In
Numerical Mathematics and Advanced Applications-ENUMATH 2013 (pp. 345-353).
Springer, Cham.
"""
function arnoldi(A, b; m=min(30, size(A, 1)), tol=1e-7, opnorm=LinearAlgebra.opnorm,
                 iop=0, cache=nothing)
    Ks = KrylovSubspace{eltype(b)}(length(b), m)
    arnoldi!(Ks, A, b; m=m, tol=tol, opnorm=opnorm, cache=cache, iop=iop)
end
"""
    arnoldi!(Ks,A,b[;tol,m,opnorm,iop,cache]) -> Ks

Non-allocating version of `arnoldi`.
"""
function arnoldi!(Ks::KrylovSubspace{B, T, U}, A, b::AbstractVector{T};
                  tol::Real=1e-7, m::Int=min(Ks.maxiter, size(A, 1)),
                  opnorm=LinearAlgebra.opnorm,
                  iop::Int=0, cache=nothing) where {B, T <: Number, U <: Number}
    if ishermitian(A)
        return lanczos!(Ks, A, b; tol=tol, m=m, opnorm=opnorm, cache=cache)
    end
    if m > Ks.maxiter
        resize!(Ks, m)
    else
        Ks.m = m # might change if happy-breakdown occurs
    end
    V, H = getV(Ks), getH(Ks)
    vtol = tol * opnorm(A, Inf)
    if iop == 0
        iop = m
    end
    # Safe checks
    n = size(V, 1)
    @assert length(b) == size(A,1) == size(A,2) == n "Dimension mismatch"
    if cache == nothing
        cache = similar(b)
    else
        @assert size(cache) == (n,) "Dimension mismatch"
    end
    # Arnoldi iterations (with IOP)
    fill!(H, zero(U))
    Ks.beta = norm(b)
    @. V[:, 1] = b / Ks.beta
    @inbounds for j = 1:m
        mul!(cache, A, @view(V[:, j]))
        @inbounds for i = max(1, j - iop + 1):j
            alpha = coeff(U, dot(@view(V[:, i]), cache))
            H[i, j] = alpha
            axpy!(-alpha, @view(V[:, i]), cache)
        end
        beta = norm(cache)
        H[j+1, j] = beta
        @inbounds for i = 1:n
            V[i, j+1] = cache[i] / beta
        end
        if beta < vtol # happy-breakdown
            Ks.m = j
            break
        end
    end
    return Ks
end
"""
    lanczos!(Ks,A,b[;tol,m,opnorm,cache]) -> Ks

A variation of `arnoldi!` that uses the Lanczos algorithm for
Hermitian matrices.
"""
function lanczos!(Ks::KrylovSubspace{B, T, U}, A, b::AbstractVector{T};
                  tol=1e-7, m=min(Ks.maxiter, size(A, 1)),
                  opnorm=LinearAlgebra.opnorm,
                  cache=nothing) where {B, T <: Number, U <: Number}
    if m > Ks.maxiter
        resize!(Ks, m)
    else
        Ks.m = m # might change if happy-breakdown occurs
    end
    V, H = getV(Ks), getH(Ks)
    vtol = tol * opnorm(A, Inf)
    # Safe checks
    n = size(V, 1)
    @assert length(b) == size(A,1) == size(A,2) == n "Dimension mismatch"
    if cache == nothing
        cache = similar(b)
    else
        @assert size(cache) == (n,) "Dimension mismatch"
    end
    # Lanczos iterations
    fill!(H, zero(T))
    Ks.beta = norm(b)
    @. V[:, 1] = b / Ks.beta
    @inbounds for j = 1:m
        vj = @view(V[:, j])
        mul!(cache, A, vj)
        alpha = coeff(U, dot(vj, cache))
        H[j, j] = alpha
        axpy!(-alpha, vj, cache)
        if j > 1
            axpy!(-H[j-1, j], @view(V[:, j-1]), cache)
        end
        beta = norm(cache)
        H[j+1, j] = beta
        if j < m
            H[j, j+1] = beta
        end
        @inbounds for i = 1:n
            V[i, j+1] = cache[i] / beta
        end
        if beta < vtol # happy-breakdown
            Ks.m = j
            break
        end
    end
    return Ks
end
