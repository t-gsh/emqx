%%--------------------------------------------------------------------
%% Copyright (c) 2020-2021 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------
-module(emqx_resource_instance).

-behaviour(gen_server).

-include("emqx_resource.hrl").
-include("emqx_resource_utils.hrl").

-export([start_link/2]).

%% load resource instances from *.conf files
-export([ lookup/1
        , get_metrics/1
        , list_all/0
        ]).

-export([ hash_call/2
        , hash_call/3
        ]).

%% gen_server Callbacks
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        , code_change/3
        ]).

-record(state, {worker_pool, worker_id}).

-type state() :: #state{}.

%%------------------------------------------------------------------------------
%% Start the registry
%%------------------------------------------------------------------------------

start_link(Pool, Id) ->
    gen_server:start_link({local, proc_name(?MODULE, Id)},
                          ?MODULE, {Pool, Id}, []).

%% call the worker by the hash of resource-instance-id, to make sure we always handle
%% operations on the same instance in the same worker.
hash_call(InstId, Request) ->
    hash_call(InstId, Request, infinity).

hash_call(InstId, Request, Timeout) ->
    gen_server:call(pick(InstId), Request, Timeout).

-spec lookup(instance_id()) -> {ok, resource_data()} | {error, Reason :: term()}.
lookup(InstId) ->
    case ets:lookup(emqx_resource_instance, InstId) of
        [] -> {error, not_found};
        [{_, Data}] ->
            {ok, Data#{id => InstId, metrics => get_metrics(InstId)}}
    end.

get_metrics(InstId) ->
    emqx_plugin_libs_metrics:get_metrics(resource_metrics, InstId).

force_lookup(InstId) ->
    {ok, Data} = lookup(InstId),
    Data.

-spec list_all() -> [resource_data()].
list_all() ->
    try
        [Data#{id => Id} || {Id, Data} <- ets:tab2list(emqx_resource_instance)]
    catch
        error:badarg -> []
    end.

%%------------------------------------------------------------------------------
%% gen_server callbacks
%%------------------------------------------------------------------------------

-spec init({atom(), integer()}) ->
    {ok, State :: state()} | {ok, State :: state(), timeout() | hibernate | {continue, term()}} |
    {stop, Reason :: term()} | ignore.
init({Pool, Id}) ->
    true = gproc_pool:connect_worker(Pool, {Pool, Id}),
    {ok, #state{worker_pool = Pool, worker_id = Id}}.

handle_call({create, InstId, ResourceType, Config, Opts}, _From, State) ->
    {reply, do_create(InstId, ResourceType, Config, Opts), State};

handle_call({create_dry_run, InstId, ResourceType, Config}, _From, State) ->
    {reply, do_create_dry_run(InstId, ResourceType, Config), State};

handle_call({recreate, InstId, ResourceType, Config, Params}, _From, State) ->
    {reply, do_recreate(InstId, ResourceType, Config, Params), State};

handle_call({remove, InstId}, _From, State) ->
    {reply, do_remove(InstId), State};

handle_call({restart, InstId}, _From, State) ->
    {reply, do_restart(InstId), State};

handle_call({stop, InstId}, _From, State) ->
    {reply, do_stop(InstId), State};

handle_call({health_check, InstId}, _From, State) ->
    {reply, do_health_check(InstId), State};

handle_call(Req, _From, State) ->
    logger:error("Received unexpected call: ~p", [Req]),
    {reply, ignored, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{worker_pool = Pool, worker_id = Id}) ->
    gproc_pool:disconnect_worker(Pool, {Pool, Id}).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%------------------------------------------------------------------------------

%% suppress the race condition check, as these functions are protected in gproc workers
-dialyzer({nowarn_function, [do_recreate/4,
                             do_create/4,
                             do_restart/1,
                             do_stop/1,
                             do_health_check/1]}).

do_recreate(InstId, ResourceType, NewConfig, Params) ->
    case lookup(InstId) of
        {ok, #{mod := ResourceType, state := ResourceState, config := OldConfig}} ->
            Config = emqx_resource:call_config_merge(ResourceType, OldConfig,
                        NewConfig, Params),
            TestInstId = iolist_to_binary(emqx_misc:gen_id(16)),
            case do_create_dry_run(TestInstId, ResourceType, Config) of
                ok ->
                    do_remove(ResourceType, InstId, ResourceState),
                    do_create(InstId, ResourceType, Config, #{force_create => true});
                Error ->
                    Error
            end;
        {ok, #{mod := Mod}} when Mod =/= ResourceType ->
            {error, updating_to_incorrect_resource_type};
        {error, not_found} ->
            {error, not_found}
    end.

do_create(InstId, ResourceType, Config, Opts) ->
    ForceCreate = maps:get(force_create, Opts, false),
    case lookup(InstId) of
        {ok, _} -> {ok, already_created};
        _ ->
            Res0 = #{id => InstId, mod => ResourceType, config => Config,
                     status => stopped, state => undefined},
            case emqx_resource:call_start(InstId, ResourceType, Config) of
                {ok, ResourceState} ->
                    ok = emqx_plugin_libs_metrics:create_metrics(resource_metrics, InstId),
                    %% this is the first time we do health check, this will update the
                    %% status and then do ets:insert/2
                    _ = do_health_check(Res0#{state => ResourceState}),
                    {ok, force_lookup(InstId)};
                {error, Reason} when ForceCreate == true ->
                    logger:error("start ~ts resource ~ts failed: ~p, "
                                 "force_create it as a stopped resource",
                                 [ResourceType, InstId, Reason]),
                    ets:insert(emqx_resource_instance, {InstId, Res0}),
                    {ok, Res0};
                {error, Reason} when ForceCreate == false ->
                    {error, Reason}
            end
    end.

do_create_dry_run(InstId, ResourceType, Config) ->
    case emqx_resource:call_start(InstId, ResourceType, Config) of
        {ok, ResourceState0} ->
            Return = case emqx_resource:call_health_check(InstId, ResourceType, ResourceState0) of
                {ok, ResourceState1} -> ok;
                {error, Reason, ResourceState1} ->
                    {error, Reason}
            end,
            _ = emqx_resource:call_stop(InstId, ResourceType, ResourceState1),
            Return;
        {error, Reason} ->
            {error, Reason}
    end.

do_remove(InstId) ->
    case lookup(InstId) of
        {ok, #{mod := Mod, state := ResourceState}} ->
            do_remove(Mod, InstId, ResourceState);
        Error ->
            Error
    end.

do_remove(Mod, InstId, ResourceState) ->
    _ = emqx_resource:call_stop(InstId, Mod, ResourceState),
    ets:delete(emqx_resource_instance, InstId),
    ok = emqx_plugin_libs_metrics:clear_metrics(resource_metrics, InstId),
    ok.

do_restart(InstId) ->
    case lookup(InstId) of
        {ok, #{mod := Mod, state := ResourceState, config := Config} = Data} ->
            _ = emqx_resource:call_stop(InstId, Mod, ResourceState),
            case emqx_resource:call_start(InstId, Mod, Config) of
                {ok, NewResourceState} ->
                    ets:insert(emqx_resource_instance,
                        {InstId, Data#{state => NewResourceState, status => started}}),
                    ok;
                {error, Reason} ->
                    ets:insert(emqx_resource_instance, {InstId, Data#{status => stopped}}),
                    {error, Reason}
            end;
        Error ->
            Error
    end.

do_stop(InstId) ->
    case lookup(InstId) of
        {ok, #{mod := Mod, state := ResourceState} = Data} ->
            _ = emqx_resource:call_stop(InstId, Mod, ResourceState),
            ets:insert(emqx_resource_instance, {InstId, Data#{status => stopped}}),
            ok;
        Error ->
            Error
    end.

do_health_check(InstId) when is_binary(InstId) ->
    case lookup(InstId) of
        {ok, Data} -> do_health_check(Data);
        Error -> Error
    end;
do_health_check(#{state := undefined}) ->
    {error, resource_not_initialized};
do_health_check(#{id := InstId, mod := Mod, state := ResourceState0} = Data) ->
    case emqx_resource:call_health_check(InstId, Mod, ResourceState0) of
        {ok, ResourceState1} ->
            ets:insert(emqx_resource_instance,
                {InstId, Data#{status => started, state => ResourceState1}}),
            ok;
        {error, Reason, ResourceState1} ->
            logger:error("health check for ~p failed: ~p", [InstId, Reason]),
            ets:insert(emqx_resource_instance,
                {InstId, Data#{status => stopped, state => ResourceState1}}),
            {error, Reason}
    end.

%%------------------------------------------------------------------------------
%% internal functions
%%------------------------------------------------------------------------------

proc_name(Mod, Id) ->
    list_to_atom(lists:concat([Mod, "_", Id])).

pick(InstId) ->
    Pid = gproc_pool:pick_worker(emqx_resource_instance, InstId),
    case is_pid(Pid) of
        true -> Pid;
        false -> error({failed_to_pick_worker, emqx_resource_instance, InstId})
    end.
