-module(bench_pgo).
-export([connect/5, query/3, coerce/1]).

connect(Host, Port, Database, User, Password) ->
    PoolName = httparena_pg_pool,
    PgoConfig = #{
        host => binary_to_list(Host),
        port => Port,
        database => binary_to_list(Database),
        user => binary_to_list(User),
        password => binary_to_list(Password),
        pool_size => 64,
        ssl => false
    },
    pgo_pool:start_link(PoolName, PgoConfig),
    PoolName.

query(Pool, Sql, Params) ->
    case pgo:query(Sql, Params, #{pool => Pool}) of
        #{command := _, num_rows := Count, rows := Rows} ->
            {ok, {Count, Rows}};
        {error, _Reason} ->
            {error, nil}
    end.

coerce(X) -> X.
