defmodule ElixirStatus.PostingController do
  use ElixirStatus.Web, :controller

  alias ElixirStatus.Publisher
  alias ElixirStatus.Posting

  plug :authenticate, :logged_in when action in [:new, :create, :edit, :update, :delete]
  plug :load_posting when action in [:edit, :update, :delete, :show]
  plug :authenticate, :same_user_or_admin when action in [:edit, :update, :delete]
  plug :authenticate, :admin when action in [:unpublish]
  plug :scrub_params, "posting" when action in [:create, :update]

  def index(conn, params) do
    page = get_all(params)
    conn
      |> ElixirStatus.Impressionist.record("frontpage")
      |> render("index.html", postings: page.entries,
                              page_number: page.page_number,
                              total_pages: page.total_pages,
                              created_posting: load_created_posting(conn),
                              changeset: Posting.changeset(%Posting{}))
  end

  def new(conn, _params) do
    render(conn, "new.html", changeset: Posting.changeset(%Posting{}))
  end

  def create(conn, %{"posting" => posting_params}) do
    posting_params = posting_params
                      |> extract_valid_params
                      |> to_create_params(conn)
    changeset = Posting.changeset(%Posting{}, posting_params)

    if changeset.valid? do
      posting = Repo.insert!(changeset)
      posting |> Publisher.after_create

      conn
        |> put_session(:created_posting_uid, posting.uid)
        |> redirect(to: posting_path(conn, :index))
    else
      render(conn, "new.html", changeset: changeset)
    end
  end

  def preview(conn, params) do
    render(conn, "preview.html",
            layout: {ElixirStatus.LayoutView, "blank.html"},
            posting: %Posting{title: params["title"], text: params["text"]})
  end

  def show(conn, %{"permalink" => _}) do
    show(conn, %{"id" => current_posting(conn)})
  end

  def show(conn, %{"id" => _}) do
    posting = current_posting(conn)

    conn
      |> ElixirStatus.Impressionist.record("detail", "postings", posting.uid)
      |> render("show.html",  posting: posting,
                              created_posting: load_created_posting(conn))
  end

  def edit(conn, %{"id" => id}) do
    posting = Repo.get!(Posting, id)
    changeset = Posting.changeset(posting)
    render(conn, "edit.html", posting: posting, changeset: changeset)
  end

  def update(conn, %{"id" => id, "posting" => posting_params}) do
    posting = Repo.get!(Posting, id)
    posting_params = posting_params |> extract_valid_params
    changeset = Posting.changeset(posting, posting_params)

    if changeset.valid? do
      Repo.update!(changeset)
        |> Publisher.after_update

      conn
        |> put_flash(:info, "Posting updated successfully.")
        |> redirect(to: posting_path(conn, :index))
    else
      render(conn, "edit.html", posting: posting, changeset: changeset)
    end
  end

  def unpublish(conn, %{"id" => id}) do
    posting = Repo.get!(Posting, id)
    changeset = Posting.changeset(posting, %{public: false})

    if changeset.valid?, do: Repo.update!(changeset)

    conn
      |> redirect(to: posting_path(conn, :index))
  end

  def delete(conn, %{"id" => id}) do
    posting = Repo.get!(Posting, id)
    Repo.delete!(posting)

    conn
      |> put_flash(:info, "Posting deleted successfully.")
      |> redirect(to: posting_path(conn, :index))
  end

  defp load_posting(conn, _) do
    posting = case conn do
      %{params: %{"id" => id}} -> get_by_id(id)
      %{params: %{"permalink" => permalink}} -> get_by_permalink(permalink)
      _ -> nil
    end
    if is_nil(posting) do
      conn
        |> put_status(:not_found)
        |> render(ElixirStatus.ErrorView, "404.html")
        |> halt
    else
      conn
        |> assign(:posting, posting)
    end
  end

  defp load_created_posting(conn) do
    uid = get_session(conn, :created_posting_uid)
    case load_created_posting_by_uid(uid)  do
      nil ->
        conn
          |> put_session(:created_posting_uid, nil)
        nil
      posting -> posting
    end
  end

  defp load_created_posting_by_uid(nil), do: nil

  defp load_created_posting_by_uid(uid) do
    get_by_uid(uid)
    # TODO: return nil if posting is older than 3 minutes
  end

  defp authenticate(conn, :logged_in) do
    case Auth.current_user(conn) do
      nil -> redirect(conn, to: "/") |> halt
      _   -> conn
    end
  end

  defp authenticate(conn, :same_user_or_admin) do
    if Auth.admin?(conn) || Auth.belongs_to_current_user?(conn, current_posting(conn)) do
      conn
    else
      redirect(conn, to: "/") |> halt
    end
  end

  defp authenticate(conn, :admin) do
    if Auth.admin?(conn) do
      conn
    else
      redirect(conn, to: "/") |> halt
    end
  end

  defp current_posting(conn) do
    conn.assigns[:posting]
  end

  defp extract_valid_params(%{"title" => title, "text" => text}) do
    %{"title" => title || "", "text" => text || ""}
  end

  defp extract_valid_params(%{"title" => title, "text" => text, "scheduled_at" => scheduled_at}) do
    %{"title" => title || "", "text" => text || "", "scheduled_at" => scheduled_at}
  end

  defp extract_valid_params(_) do
    %{}
  end

  defp to_create_params(params, conn) do
    uid = ElixirStatus.UID.generate(Posting)
    %{
      user_id: Auth.current_user(conn).id,
      uid: uid,
      permalink: Publisher.permalink(uid, params["title"]),
      text: params["text"],
      title: params["title"],
      scheduled_at: params["scheduled_at"],
      published_at: Ecto.DateTime.utc,
      public: true
    }
  end

  def get_all(params \\ %{}) do
    query = from p in Posting,
                  where: p.public == ^true,
                  order_by: [desc: :published_at]
    query |> Ecto.Query.preload(:user) |> Repo.paginate(params)
  end

  defp get_by_id(id) do
    query = from(p in Posting, where: p.id == ^id)
    query |> Ecto.Query.preload(:user) |> Repo.one
  end

  defp get_by_permalink(permalink) do
    String.split(permalink, "-") |> Enum.at(0) |> get_by_uid
  end

  defp get_by_uid(uid) do
    query = from(p in Posting, where: p.uid == ^uid)
    query |> Ecto.Query.preload(:user) |> Repo.one
  end
end
