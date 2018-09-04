## generic `Tables.rows` and `Tables.columns` fallbacks
## if a table provides Tables.rows or Tables.columns,
## we'll provide a default implementation of the dual

# generic row iteration of columns
struct ColumnsRow{T}
    columns::T # a `Columns` object
    row::Int
end

Base.getproperty(c::ColumnsRow, ::Type{T}, col::Int, nm::Symbol) where {T} = getproperty(getfield(c, 1), T, col, nm)[getfield(c, 2)]
Base.getproperty(c::ColumnsRow, nm::Symbol) = getproperty(getfield(c, 1), nm)[getfield(c, 2)]
Base.propertynames(c::ColumnsRow) = propertynames(c.columns)

struct RowIterator{T}
    columns::T
end
Base.eltype(x::RowIterator{T}) where {T} = ColumnsRow{T}
Base.length(x::RowIterator) = length(getproperty(x.columns, propertynames(x.columns)[1]))
schema(x::RowIterator) = schema(x.columns)

function Base.iterate(rows::RowIterator, st=1)
    st > length(rows) && return nothing
    return ColumnsRow(rows.columns, st), st + 1
end

function rows(x::T) where {T}
    if columnaccess(T)
        return RowIterator(columns(x))
    else
        throw(ArgumentError("no default `Tables.rows` implementation for type: $T"))
    end
end

# build columns from rows
"""
    Tables.allocatecolumn(::Type{T}, len) => returns a column type (usually AbstractVector) w/ size to hold `len` elements
    
    Custom column types can override with an appropriate "scalar" element type that should dispatch to their column allocator.
"""
allocatecolumn(T, len) = Vector{T}(undef, len)

@inline function allocatecolumns(::Schema{names, types}, len) where {names, types}
    if @generated
        vals = Tuple(:(allocatecolumn($(fieldtype(types, i)), len)) for i = 1:fieldcount(types))
        return :(NamedTuple{names}(($(vals...),)))
    else
        return NamedTuple{names}(Tuple(allocatecolumn(fieldtype(types, i), len) for i = 1:fieldcount(types)))
    end
end

haslength(x) = x === Base.HasLength() || x === Base.HasShape{1}()

# add! will push! or setindex! a value depending on if the row-iterator HasLength or not
@inline add!(val, col::Int, nm::Symbol, ::Union{Base.HasLength, Base.HasShape{1}}, nt, row) = setindex!(nt[col], val, row)
@inline add!(val, col::Int, nm::Symbol, T, nt, row) = push!(nt[col], val)

@inline function buildcolumns(schema, rowitr::T) where {T}
    L = Base.IteratorSize(T)
    len = haslength(L) ? length(rowitr) : 0
    nt = allocatecolumns(schema, len)
    for (i, row) in enumerate(rowitr)
        eachcolumn(add!, schema, row, L, nt, i)
    end
    return nt
end

@inline function add_or_widen!(val::T, col::Int, nm::Symbol, L, columns, row, allocate, len) where {T}
    if !allocate
        @inbounds columns[col] = add_or_widen!(columns[col], val, L, row)
    else
        @inbounds columns[col] = add_or_widen!(allocatecolumn(T, len), val, L, row)
    end
    return
end

@inline add!(dest::AbstractVector, val, ::Union{Base.HasLength, Base.HasShape{1}}, row) = setindex!(dest, val, row)
@inline add!(dest::AbstractVector, val, T, row) = push!(dest, val)

@inline function add_or_widen!(dest::AbstractVector{T}, val::S, L, row) where {T, S}
    if S === T || val isa T
        add!(dest, val, L, row)
        return dest
    else
        new = allocatecolumn(Base.promote_typejoin(T, S), length(dest))
        copyto!(new, 1, dest, 1, row - 1)
        add!(new, val, L, row)
        return new
    end
end

# when Tables.schema(x) === nothing
function buildcolumns(::Nothing, rowitr::T) where {T}
    state = iterate(rowitr)
    state === nothing && return NamedTuple()
    row::eltype(rowitr), st = state
    names = propertynames(row)
    cols = length(names)
    L = Base.IteratorSize(T)
    len = haslength(L) ? length(rowitr) : 0
    columns = Vector{AbstractVector}(undef, cols)
    eachcolumn(add_or_widen!, names, row, L, columns, 1, true, len)
    rownbr = 2
    while true
        state = iterate(rowitr, st)
        state === nothing && break
        row, st = state
        eachcolumn(add_or_widen!, names, row, L, columns, rownbr, false, len)
        rownbr += 1
    end
    return NamedTuple{names}(Tuple(columns))
end

@inline function columns(x::T) where {T}
    if rowaccess(T)
        r = rows(x)
        return buildcolumns(schema(r), r)
    else
        throw(ArgumentError("no default `Tables.columns` implementation for type: $T"))
    end
end
