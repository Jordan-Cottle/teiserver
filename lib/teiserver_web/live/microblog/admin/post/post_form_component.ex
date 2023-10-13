defmodule TeiserverWeb.Microblog.PostFormComponent do
  @moduledoc false
  use CentralWeb, :live_component
  import Teiserver.Helper.ColourHelper, only: [rgba_css: 2]

  alias Teiserver.{Communication, Microblog, Account}
  alias Teiserver.Account.AuthLib

  @default_channel_name "Dev updates"

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <style type="text/css">
        .tag-selector {
          cursor: pointer;
          border: 1px solid #FFF;
          font-size: 1em;
        }
      </style>

      <h3>
        <%= @title %>
      </h3>

      <.form for={@form}
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <div class="row mb-4">
          <div class="col">
            <label for="post_title" class="control-label">Title:</label>
            <.input
              field={@form[:title]}
              type="text"
              autofocus="autofocus"
              phx-debounce="100"
            />
            <br />

            <label for="post_contents" class="control-label">Contents:</label>
            &nbsp;
            <em>Markdown, use a double-line return to split small version from full version.</em>
            <textarea
              name="post[contents]"
              id="post_contents"
              rows="8"
              phx-debounce="100"
              class="form-control"><%= @form[:contents].value %></textarea>
          </div>
          <div class="col">
            <h4>Tags</h4>
            <%= for tag <- @tags do %>
              <%= if Enum.member?(@selected_tags, tag.id) do %>
                <span class="badge rounded-pill m-1 tag-selector" style={"background-color: #{tag.colour}; "} phx-click="toggle-selected-tag" phx-value-tag={tag.id} phx-target={@myself}>
                  <Fontawesome.icon icon={tag.icon} style="solid" />
                  <%= tag.name %>
                </span>
              <% else %>
                <span class="badge rounded-pill m-1 tag-selector" style={"background-color: #{rgba_css(tag.colour, 0.5)}; border-color: rgba(0,0,0,0);"} phx-click="toggle-selected-tag" phx-value-tag={tag.id} phx-target={@myself}>
                  <Fontawesome.icon icon={tag.icon} style="regular" />
                  <%= tag.name %>
                </span>
              <% end %>
            <% end %>
            <br /><br />

            <h4>Discord channel</h4>
            <.input
              field={@form[:discord_channel_id]}
              type="select"
              options={@discord_channels}
            />
            <%= if false and @current_user.discord_id == nil do %>
              <div class="alert alert-info mt-4" style="font-size: 0.9em;">
                You have not linked your discord account with your game account. Currently you can do this by chatting <span class="monospace">$discord</span> in a public room and the server will send you a one time code to send the bridge.

                You can still post microblog messages to discord but it will not include your name/profile in them.
              </div>
            <% end %>

          </div>
        </div>

        <% disabled = if not @form.source.valid? or Enum.empty?(@selected_tags), do: "disabled" %>
        <%= if @post.id do %>
          <div class="row">
            <div class="col">
              <a href={~p"/microblog/show/#{@post.id}"} class="btn btn-secondary btn-block">
                Cancel
              </a>
            </div>
            <div class="col">
              <%= submit("Update post", class: "btn btn-primary btn-block #{disabled}") %>
            </div>
          </div>
        <% else %>
          <%= submit("Post", class: "btn btn-primary btn-block #{disabled}") %>
        <% end %>
      </.form>
    </div>
    """
  end

  @impl true
  def update(%{post: post} = assigns, socket) do
    tags = Microblog.list_tags(
      order_by: [
        "Name (A-Z)"
      ]
    )

    discord_channels = Communication.list_discord_channels(
      order_by: [
        "Name (A-Z)"
      ]
    )
    |> Enum.filter(fn channel ->
      not String.contains?(channel.name, "(counter)")
      and
      AuthLib.allow?(assigns.current_user, channel.post_permission)
    end)
    |> Enum.map(fn channel ->
      {channel.name, channel.id}
    end)

    changeset = if post.id do
      Microblog.change_post(post)
    else
      default_channel_id = case Communication.get_discord_channel(@default_channel_name) do
        nil -> nil
        %{id: id} -> id
      end

      Microblog.change_post(post, %{discord_channel_id: default_channel_id})
    end

    {:ok,
     socket
     |> assign(:tags, tags)
     |> assign(:discord_channels, [{"No channel", nil} | discord_channels])
     |> assign(:selected_tags, assigns[:selected_tags] || [])
     |> assign(:originally_selected_tags, assigns[:selected_tags] || [])
     |> assign(assigns)
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("validate", %{"post" => post_params}, socket) do
    post_params = Map.merge(post_params, %{
      "poster_id" => socket.assigns.current_user.id
    })

    changeset =
      socket.assigns.post
      |> Microblog.change_post(post_params)
      |> Map.put(:action, :validate)

    notify_parent({:updated_changeset, changeset})

    {:noreply, socket
      |> assign_form(changeset)
    }
  end

  def handle_event("save", %{"post" => post_params}, socket) do
    save_post(socket, socket.assigns.action, post_params)
  end

  def handle_event("toggle-selected-tag", %{"tag" => tag_id_str}, socket) do
    tag_id = String.to_integer(tag_id_str)

    new_selected_tags = if Enum.member?(socket.assigns.selected_tags, tag_id) do
      List.delete(socket.assigns.selected_tags, tag_id)
    else
      [tag_id | socket.assigns.selected_tags] |> Enum.uniq
    end

    {:noreply, socket
      |> assign(:selected_tags, new_selected_tags)
    }
  end

  defp save_post(socket, :edit, post_params) do
    case Microblog.update_post(socket.assigns.post, post_params) do
      {:ok, post} ->
        deleted_tags = socket.assigns.originally_selected_tags
          |> Enum.reject(fn tag_id ->
            Enum.member?(socket.assigns.selected_tags, tag_id)
          end)

        Microblog.delete_post_tags(post.id, deleted_tags)

        added_tags = socket.assigns.selected_tags
          |> Enum.reject(fn tag_id ->
            Enum.member?(socket.assigns.originally_selected_tags, tag_id)
          end)
          |> Enum.map(fn tag_id ->
            %{
              tag_id: tag_id,
              post_id: post.id
            }
          end)

        Ecto.Multi.new()
        |> Ecto.Multi.insert_all(:insert_all, Teiserver.Microblog.PostTag, added_tags)
        |> Teiserver.Repo.transaction()

        notify_parent({:saved, post})

        update_post_to_discord(post)

        {:noreply,
         socket
         |> put_flash(:info, "Post updated successfully")
         |> redirect(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp save_post(socket, :new, post_params) do
    post_params = Map.merge(post_params, %{
      "poster_id" => socket.assigns.current_user.id
    })

    case Microblog.create_post(post_params) do
      {:ok, post} ->
        post_tags = socket.assigns.selected_tags
          |> Enum.map(fn tag_id ->
            %{
              tag_id: tag_id,
              post_id: post.id
            }
          end)

        Ecto.Multi.new()
        |> Ecto.Multi.insert_all(:insert_all, Teiserver.Microblog.PostTag, post_tags)
        |> Teiserver.Repo.transaction()

        notify_parent({:saved, post})

        create_post_to_discord(post)

        {:noreply,
         socket
         |> put_flash(:info, "Post created successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset))
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})

  defp create_post_to_discord(%{discord_channel_id: nil}), do: :ok
  defp create_post_to_discord(post) do
    content = create_discord_text(post)
    case Communication.new_discord_message(post.discord_channel_id, content) do
      {:ok, %{id: message_id}} ->
        Microblog.update_post(post, %{"discord_post_id" => message_id})

      _ ->
        :ok
    end
  end

  defp update_post_to_discord(%{discord_channel_id: nil}), do: :ok
  defp update_post_to_discord(%{discord_post_id: nil} = post), do: create_post_to_discord(post)
  defp update_post_to_discord(post) do
    content = create_discord_text(post)
    case Communication.edit_discord_message(post.discord_channel_id, post.discord_post_id, content) do
      {:ok, _new_message} ->
        :ok
      {:error, %{status_code: 404}} ->
        create_post_to_discord(post)
    end
  end

  defp create_discord_text(post) do
    post_content = post.contents
      |> String.split("\n\n")
      |> hd
      |> String.trim()

    user = Account.get_user_by_id(post.poster_id)
    discord_tag = if user.discord_id do
      " - Posted by <@#{user.discord_id}>"
    else
      " - Posted by #{user.name}"
    end

    host = Application.get_env(:central, TeiserverWeb.Endpoint)[:url][:host]
    url = "https://#{host}/microblog/show/#{post.id}"

    "-------------------------------\n**#{post.title}**#{discord_tag}\n#{post_content}\n\n[See full text](#{url})"
  end
end
