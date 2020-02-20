struct AllocationReplay{A}
    allocations::A
    step::Ref{Int}
end

AllocationReplay(record) = AllocationReplay(record.allocations, Ref(1))

Cassette.@context ReplayCtx
new_replay_ctx(record) = new_replay_ctx(AllocationReplay(record))
function new_replay_ctx(replay::AllocationReplay)
    #replay.step[] = 1
    return Cassette.disablehooks(ReplayCtx(metadata=replay))
end


@inline function next_scheduled_alloc!(replay::AllocationReplay)
    step = replay.step[] :: Int
    alloc = replay.allocations[step] :: Array
    replay.step[] = step + 1
    return alloc
end
@inline next_scheduled_alloc!(ctx::ReplayCtx) = next_scheduled_alloc!(ctx.metadata)

@inline function Cassette.overdub(
    ctx::ReplayCtx, ::Type{Array{T,N}}, ::UndefInitializer, dims
)::Array{T,N} where {T,N}
    scheduled = next_scheduled_alloc!(ctx) :: Array{T,N}

    # Commented out until we can workout how to do this without allocations on the happy path
    # It seems like having any branch here makes it allocate
    # TODO: reenable this
    #==
    if  typeof(scheduled) !== Array{T,N} || size(scheduled) !== dims
        @warn "Allocation reuse failed. Indicates value dependent allocations." step=ctx.metadata.step[] expected_T=eltype(scheduled) actual_T=T expected_size=size actual_size=dims
        # Fallback to just doing the allocation
        return Array{T,N}(undef, dims)
    end
    ==#

    return scheduled
end


const WHITE_LIST = [
    Base.promote_op, Base.to_shape,
    Core.getfield,
    Core.:(===),
    Base.iterate,
    Broadcast.broadcasted, Broadcast.instantiate,
    Broadcast.preprocess, Base.not_int,
    Base.size,
    Tuple,
]

for F in WHITE_LIST
    @eval @inline Cassette.overdub(ctx::RecordingCtx, f::typeof($F), xs...) = f(xs...)
    @eval @inline Cassette.overdub(ctx::ReplayCtx, f::typeof($F), xs...) = f(xs...)
end

function avoid_allocations(record, f, args...; kwargs...)
    ctx = new_replay_ctx(record)
    return Cassette.overdub(ctx, f, args...; kwargs...)
end
