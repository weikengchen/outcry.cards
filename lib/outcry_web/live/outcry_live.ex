defmodule OutcryWeb.OutcryLive do
  use Phoenix.{LiveView, HTML}
  alias OutcryWeb.MatchmakingPresence

  @impl true
  def mount(%{}, socket) do
    {:ok,
     socket
     |> assign(user_id: inspect(self()), status: :in_queue),
     temporary_assigns: [trade_message: nil]}
  end

  @impl true
  def handle_params(%{}, _params, socket) do
    channel = Outcry.Matchmaker.channel()
    {:ok, _} = MatchmakingPresence.track(self(), channel, socket.assigns.user_id, %{pid: self()})

    {:noreply, socket}
  end

  @impl true
  def handle_info(
        %{event: "game_start", game_pid: game_pid},
        %{assigns: %{status: :in_queue}} = socket
      ) do
    channel = Outcry.Matchmaker.channel()
    :ok = MatchmakingPresence.untrack(self(), channel, socket.assigns.user_id)

    {:noreply, socket |> assign(status: :game_starting, game_pid: game_pid)}
  end

  @impl true
  def handle_info(%{event: "state_update", state: state}, socket) do
    # LiveView change tracking only tracks assigns directly,
    # so we flatten our state a little here.
    order_books = reverse_order_book_buys(state.order_books)
    {:noreply,
     socket |> assign(players: state.players, order_books: order_books, status: :game_started)}
  end

  @impl true
  def handle_info(%{event: "trade"} = trade_message, socket) do
    {:noreply, socket |> assign(trade_message: trade_message)}
  end

  @impl true
  def handle_info(%{event: "game_over", score_info: score_info}, socket) do
    {:noreply, socket |> assign(status: :game_over, score_info: score_info)}
  end

  defp reverse_order_book_buys(order_books) do
    Map.new(order_books, fn {suit, order_book} ->
      {suit, update_in(order_book.buy, &Enum.reverse/1)}
    end)
  end

  defp error_for(element, message) do
    {:error, [{element, {message, []}}]}
  end

  @trades_per_second 4
  defp rate_limit(socket) do
    case ExRated.check_rate(socket.assigns.user_id, 1_000, @trades_per_second) do
      {:error, _} -> error_for("submit", "trading too fast, wait one second.")
      {:ok, _} = ok -> ok
    end
  end

  defp to_struct(kind, attrs) do
    struct = struct(kind)

    Enum.reduce(Map.to_list(struct), struct, fn {k, _}, acc ->
      case Map.fetch(attrs, Atom.to_string(k)) do
        {:ok, v} -> %{acc | k => v}
        :error -> acc
      end
    end)
  end

  defp order_to_struct(order) do
    alias Outcry.Game.Orders.{Limit, Market, Cancel}

    case Map.get(order, "type") do
      "limit" -> Limit
      "market" -> Market
      "cancel" -> Cancel
      _ -> :error
    end
    |> case do
      :error ->
        error_for("order_type", "invalid order type.")

      m ->
        {:ok, to_struct(m, order)}
    end
  end

  @impl true
  def handle_event("order", %{"order" => order}, socket) do
    with {:ok, _} <- rate_limit(socket),
         {:ok, order} <- order_to_struct(order),
         :ok <- Outcry.Game.Player.place_order(self(), socket.assigns.game_pid, order) do
      :ok
    end
    |> case do
      :ok ->
        {:noreply, socket |> assign(errors: nil)}

      {:error, error_messages} ->
        {:noreply, socket |> assign(errors: error_messages)}
    end
  end

  @impl true
  def render(assigns) do
    ~L"""
    <%= case @status do %>
      <% :in_queue -> %> <h1>Looking for game...</h1>
      <% :game_started -> %>
      <div class="tile is-ancestor">
        <div class="tile is-parent is-vertical">
          <div class="tile is-parent">
            <%= Phoenix.View.render(OutcryWeb.GameView, "points.html", assigns) %>
            <%= Phoenix.View.render(OutcryWeb.GameView, "order_book.html", assigns) %>
            <%= Phoenix.View.render(OutcryWeb.GameView, "trade_history.html", assigns) %>
          </div>
          <%= Phoenix.View.render(OutcryWeb.GameView, "order_form.html", %{}) %>
        </div>
      </div>
      <% :game_starting -> %>
      <% :game_over -> %>
      <h1>Game finished!</h1>

      <pre><%= inspect @score_info, pretty: true %></pre>
    <% end %>
    """
  end
end
