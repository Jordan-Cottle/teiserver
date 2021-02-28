defmodule Central.Config do
  @moduledoc """
  The Config context.
  """

  import Ecto.Query, warn: false
  alias Central.Repo

  alias Central.Config.UserConfig

  def get_user_config_cache(%{assigns: %{current_user: nil}}, key) do
    get_user_config_default(key)
  end

  def get_user_config_cache(%{assigns: %{current_user: current_user}}, key) do
    get_user_config_cache(current_user.id, key)
  end

  def get_user_config_cache(user_id, key) do
    value = get_user_configs!(user_id)[key]

    if value do
      cast_user_config_value(key, value)
    else
      get_user_config_default(key)
    end
  end

  def set_user_config(%{assigns: %{current_user: current_user}}, key, value),
    do: set_user_config(current_user.id, key, value)

  def set_user_config(user_id, key, nil) do
    user_configs = get_user_configs!(user_id)

    if user_configs[key] != nil do
      get_user_config!(user_id, key)
      |> delete_user_config
    end
  end

  def set_user_config(user_id, key, value) do
    user_configs = get_user_configs!(user_id)

    if user_configs[key] == nil do
      create_user_config(%{
        "user_id" => user_id,
        "key" => key,
        "value" => value |> to_string
      })
    else
      get_user_config!(user_id, key)
      |> update_user_config(%{
        "value" => value |> to_string
      })
    end
  end

  @doc """
  Gets a single user_config.

  Raises `Ecto.NoResultsError` if the User config does not exist.

  ## Examples

      iex> get_user_config!(123)
      %UserConfig{}

      iex> get_user_config!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user_configs!(nil), do: %{}

  def get_user_configs!(user_id) do
    ConCache.get_or_store(:config_user_cache, user_id, fn ->
      query =
        from(user_config in UserConfig,
          where: user_config.user_id == ^user_id,
          select: {user_config.key, user_config.value}
        )

      Repo.all(query)
      |> Map.new()
    end)
  end

  def get_user_config!(id), do: Repo.get!(UserConfig, id)

  def get_user_config!(user_id, key) do
    query =
      from(user_config in UserConfig,
        where: user_config.user_id == ^user_id,
        where: user_config.key == ^key,
        limit: 1
      )

    Repo.one(query)
  end

  @doc """
  Creates a user_config.

  ## Examples

      iex> create_user_config(%{field: value})
      {:ok, %UserConfig{}}

      iex> create_user_config(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_user_config(attrs \\ %{}) do
    ConCache.dirty_delete(:config_user_cache, attrs["user_id"])

    %UserConfig{}
    |> UserConfig.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a user_config.

  ## Examples

      iex> update_user_config(user_config, %{field: new_value})
      {:ok, %UserConfig{}}

      iex> update_user_config(user_config, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_config(%UserConfig{} = user_config, attrs) do
    ConCache.dirty_delete(:config_user_cache, user_config.user_id)

    user_config
    |> UserConfig.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a UserConfig.

  ## Examples

      iex> delete_user_config(user_config)
      {:ok, %UserConfig{}}

      iex> delete_user_config(user_config)
      {:error, %Ecto.Changeset{}}

  """
  def delete_user_config(%UserConfig{} = user_config) do
    ConCache.dirty_delete(:config_user_cache, user_config.user_id)
    Repo.delete(user_config)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking user_config changes.

  ## Examples

      iex> change_user_config(user_config)
      %Ecto.Changeset{source: %UserConfig{}}

  """
  def change_user_config(%UserConfig{} = user_config) do
    ConCache.dirty_delete(:config_user_cache, user_config.user_id)
    UserConfig.changeset(user_config, %{})
  end

  # Types
  def get_config_types() do
    ConCache.get(:config_type_cache, "all-config-types")
  end

  def get_config_type(key) do
    ConCache.get(:config_type_cache, key)
  end

  def get_grouped_configs() do
    ConCache.get(:config_type_cache, "all-config-types")
    |> Map.values()
    |> Enum.filter(fn c ->
      c.visible
    end)
    |> Enum.sort(fn c1, c2 ->
      c1.key <= c2.key
    end)
    |> Enum.group_by(fn c ->
      hd(String.split(c.key, "."))
    end)
  end

  # def update_user_config(user_id, key, value) do
  #   Cache.add(user_id, key, value)
  # end

  @doc """
  Expects a map with the following fields:

    key: String, dot notation indicating namespace and name of config; spaces allowed
      e.g. account.Favourite colour

    section: String, the tab it would appear under in an options menu. Does not need to be the same as the keyed namespace,
      e.g. "Colours"

    type: String, choose from: string, password, boolean, array
      array allows the picking of multiple options

    visible: Boolean, dictates if it is visible in the account settings page

    permissions: Permission list, decides if it can be edited on the account page

    description: String, Information presented to the user if they edit it on their settings page

    opts: List, used to define options for various data types. If set then only items from the list will be selectable

    default: Any, The default value used when the variable is not set,
  """
  require Logger

  def add_user_config_type(config) do
    all_config_types =
      (ConCache.get(:config_type_cache, "all-config-types") || %{})
      |> Map.put(config.key, config)

    ConCache.put(:config_type_cache, "all-config-types", all_config_types)
    ConCache.put(:config_type_cache, config.key, config)
  end

  def get_user_config_default(key) do
    case get_config_type(key) do
      nil -> throw("Invalid config key of #{key}")
      v -> Map.get(v, :default)
    end
  end

  def cast_user_config_value(type_key, value) do
    type = get_config_type(type_key)

    case type.type do
      "integer" -> Central.Helpers.NumberHelper.int_parse(value)
      "boolean" -> if value == "true", do: true, else: false
      "string" -> value
    end
  end
end
