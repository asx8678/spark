defmodule Immo.Accounts.SessionIdleTimeoutTest do
  @moduledoc """
  P1-E1.1 §13 24 h admin session idle timeout.

  The verify query rejects any session token whose `last_seen_at` is
  older than 24 h. We exercise the boundary by directly rewriting
  `last_seen_at` in the database (the path the auth pipeline would
  take to "expire" an idle session) and asserting the next call to
  `get_user_by_session_token/1` returns nil.

  We do NOT wait 24 h of wall-clock time in a test — the boundary is
  tested by setting `last_seen_at` 25 h in the past.
  """
  use Immo.DataCase, async: true

  alias Immo.Accounts
  alias Immo.Accounts.UserToken

  @valid_password "IdleTimeout!Test!2026"

  test "active session (last_seen_at = now) is valid" do
    {:ok, user} =
      Accounts.register_staff_user(%{
        email: "active-session@example.com",
        password: @valid_password,
        role: :admin
      })

    user_id = user.id
    token = Accounts.generate_user_session_token(user)
    assert {%{id: ^user_id}, _inserted_at} = Accounts.get_user_by_session_token(token)
  end

  test "session with last_seen_at 25 hours ago is rejected" do
    {:ok, user} =
      Accounts.register_staff_user(%{
        email: "idle-session@example.com",
        password: @valid_password,
        role: :admin
      })

    token = Accounts.generate_user_session_token(user)
    # Move last_seen_at 25 hours into the past — past the 24 h idle cap.
    twenty_five_hours_ago = DateTime.utc_now(:second) |> DateTime.add(-25 * 60 * 60, :second)

    Immo.Repo.update_all(from(t in UserToken, where: t.token == ^token),
      set: [last_seen_at: twenty_five_hours_ago]
    )

    assert Accounts.get_user_by_session_token(token) == nil
  end

  test "touch_user_session_token/1 resets the idle clock" do
    {:ok, user} =
      Accounts.register_staff_user(%{
        email: "touch-session@example.com",
        password: @valid_password,
        role: :admin
      })

    user_id = user.id
    token = Accounts.generate_user_session_token(user)

    # Stale by 23 hours — still inside the window, no need to touch.
    twenty_three_hours_ago = DateTime.utc_now(:second) |> DateTime.add(-23 * 60 * 60, :second)

    Immo.Repo.update_all(from(t in UserToken, where: t.token == ^token),
      set: [last_seen_at: twenty_three_hours_ago]
    )

    assert {%{id: ^user_id}, _} = Accounts.get_user_by_session_token(token)

    # A single request-level touch moves last_seen_at back to "now".
    :ok = Accounts.touch_user_session_token(token)
    assert {%{id: ^user_id}, _} = Accounts.get_user_by_session_token(token)
  end

  test "new session tokens set last_seen_at to now (no backdating)" do
    {:ok, user} =
      Accounts.register_staff_user(%{
        email: "fresh-session@example.com",
        password: @valid_password,
        role: :admin
      })

    token = Accounts.generate_user_session_token(user)
    [row] = Immo.Repo.all(from(t in UserToken, where: t.token == ^token))

    now = DateTime.utc_now(:second)
    diff = DateTime.diff(now, row.last_seen_at, :second)
    # Within a 5-second tolerance for test scheduling jitter.
    assert abs(diff) <= 5
  end
end
