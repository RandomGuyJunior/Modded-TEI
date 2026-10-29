defmodule Teiserver.Protocols.Spring.BattleIn do
  @moduledoc false
  alias Teiserver.Battle
  alias Teiserver.Coordinator
  alias Teiserver.Lobby
  alias Teiserver.Lobby.LobbyLib
  alias Teiserver.Protocols.SpringIn
  require Logger
  import Teiserver.Protocols.SpringOut, only: [reply: 5]
  import Teiserver.Helper.NumberHelper, only: [int_parse: 1]

  @spec do_handle(String.t(), String.t(), String.t() | nil, map()) :: map()
  def do_handle("update_lobby_title", new_name, msg_id, state) do
    case LobbyLib.validate_name(new_name) do
      {:error, error} ->
        reply(:spring, :no, {"c.battle.update_lobby_title", error}, msg_id, state)

      :ok ->
        if Lobby.allow?(state.userid, :update_lobby_title, state.lobby_id) do
          Battle.rename_lobby(state.lobby_id, new_name, nil)
          reply(:spring, :okay, "c.battle.update_lobby_title", msg_id, state)
        else
          state
        end
    end
  end

  def do_handle("update_host", json_str, _msg_id, state) do
    case Jason.decode(json_str) do
      {:ok, data} ->
        host_data = %{
          # host_bosses: [User.get_userid(data["boss"])],
          host_teamsize: data["teamSize"] |> int_parse(),
          host_teamcount: data["nbTeams"] |> int_parse()
        }

        Coordinator.cast_consul(state.lobby_id, {:host_update, state.userid, host_data})

      v ->
        Logger.error(
          "update_spads instruction error #{Kernel.inspect(v)}, tried to decode #{json_str}"
        )
    end

    state
  end

  def do_handle("queue_status", _data, _msg_id, %{lobby_id: nil} = state), do: state

  def do_handle(
        "queue_status",
        _data,
        _msg_id,
        %{lobby_id: lobby_id, app_status: :accepted} = state
      ) do
    id_list = Coordinator.call_consul(lobby_id, :queue_state)
    reply(:battle, :queue_status, {lobby_id, id_list}, nil, state)
  end

  def do_handle("queue_status", _data, _msg_id, state), do: state


  # Register battle capabilities without using chat.
  # Only an authenticated battle host can request registration.
  def do_handle(
        "mod_capabilities",
        "rapid-mods-v1",
        _msg_id,
        %{lobby_id: lobby_id, lobby_host: true, userid: userid} = state
      )
      when is_integer(lobby_id) do
    Logger.info("[ModHubTrace] SPADS capability received host=#{userid} battle=#{lobby_id}")
    Coordinator.cast_consul(
      lobby_id,
      {:register_mod_hub_capabilities, userid, ["rapid-mods-v1"]}
    )

    state
  end

  # Host-authenticated inventory registration; no chat transport.
  def do_handle("mod_inventory", data, _msg_id,
        %{lobby_id: lobby_id, lobby_host: true, userid: userid} = state)
      when is_integer(lobby_id) and is_binary(data) and byte_size(data) <= 8192 do
    tags = if data in ["", "-"], do: [], else: String.split(data, ",")
    if length(tags) <= 128 and Enum.all?(tags, &Regex.match?(~r/\A[A-Za-z0-9_-]+:[A-Za-z0-9_-]+\z/, &1)) do
      Coordinator.cast_consul(lobby_id, {:register_mod_inventory, userid, tags})
    end
    state
  end

  # Active Rapid mods are separate from merely downloaded archives.
  # Only the authenticated battle host may publish this state.
  def do_handle("mod_enabled", data, _msg_id,
        %{lobby_id: lobby_id, lobby_host: true, userid: userid} = state)
      when is_integer(lobby_id) and is_binary(data) and byte_size(data) <= 8192 do
    tags = if data in ["", "-"], do: [], else: String.split(data, ",")
    if length(tags) <= 128 and Enum.all?(tags, &Regex.match?(~r/\\A[A-Za-z0-9_-]+:[A-Za-z0-9_-]+\\z/, &1)) do
      Coordinator.cast_consul(lobby_id, {:register_mod_enabled, userid, tags})
    end
    state
  end

  def do_handle("mod_enabled", _data, _msg_id, state), do: state

  def do_handle("mod_inventory", _data, _msg_id, state), do: state

  def do_handle("mod_capabilities", _data, _msg_id, state) do
    Logger.warning("[ModHubTrace] SPADS capability rejected battle=#{inspect(Map.get(state, :lobby_id))} host=#{inspect(Map.get(state, :lobby_host))}")
    state
  end

  def do_handle("extra_data", _data, _msg_id, %{lobby_id: nil} = state) do
    Logger.warning("[ModHubTrace] Chobby extra_data rejected: no battle")
    state
  end

  def do_handle(
        "extra_data",
        _data,
        _msg_id,
        %{lobby_id: lobby_id, app_status: :accepted} = state
      ) do
    Logger.info("[ModHubTrace] Chobby extra_data received battle=#{lobby_id}")
    data = Coordinator.call_consul(lobby_id, :get_chobby_extra_data)
    Logger.info("[ModHubTrace] TEI response battle=#{lobby_id} capabilities=#{inspect(data && Map.get(data, :mod_hub_capabilities))}")
    reply(:battle, :extra_data, {lobby_id, data}, nil, state)
  end

  def do_handle("extra_data", _data, _msg_id, state) do
    Logger.warning("[ModHubTrace] Chobby extra_data rejected battle=#{inspect(Map.get(state, :lobby_id))} status=#{inspect(Map.get(state, :app_status))}")
    state
  end

  def do_handle(cmd, data, msg_id, state) do
    SpringIn._no_match(state, "c.battle." <> cmd, msg_id, data)
  end
end
