defmodule PhoenixKitAgent.Prompt do
  @moduledoc """
  The system prompt of a turn (spec §7.1), put together in the order of
  priority, each part separated by a blank line:

    1. the module's prompt (`agent_system_prompt`, `PhoenixKitAgent.Config`),
       then the module's own rule for writes, always there: a tool that
       changes data only proposes the change, which waits for the user's
       confirmation in the chat, and the model never says it is done before a
       confirmation message says so, nor asks again for a change still
       waiting (`PhoenixKitAgent.Confirmations`); then, when the AI guard
       has the `agent.chat` task flag off-purpose requests
       (`PhoenixKitAI.Guard.self_flag?/1`), the guard's instruction
       (`PhoenixKitAI.Guard.self_flag_instruction/1`) and how to flag: the
       marker `⟦off_purpose: <reason>⟧` at the very end of the answer, which
       the turn cuts off (`PhoenixKitAgent.Turns.Runner`). It stands above
       everything the admin and the user write, so their instructions cannot
       undo it, and above the date, so the prompt's cached prefix holds;
    2. the host's addendum — `config :phoenix_kit_agent, prompt_addendum:
       {Mod, :fun}`: what an order is, the statuses, the language of the
       answer. `Mod.fun(ctx)` is called with `%{user_uuid:, locale:}` when it
       is exported with one argument, `Mod.fun()` otherwise; the result is a
       string or `nil`. An exception, an exit, a result that is not a string
       or a function that does not exist skips the addendum with a warning
       that names the reason only — never the content;
    3. the admin's prompt for this user (`UserSettings.system_prompt`);
    4. the user's personal instructions (`personal_instructions`), under a line
       that says they rank below the parts above and never override them;
    5. the context of the session: the user's name (never the e-mail), the
       role the session acts as, the locale, the date in the site time zone
       (not the time of day: the system message opens every request, and a
       prefix that changes by the minute defeats the providers' prompt
       caching), the page's path when the host passed it to
       `PhoenixKitAgent.Turns.start/6`, and what the host says of that page
       (below).

  The page and the locale come from a browser, so they are not trusted: a
  value with a control or line-separator character, or one that is not shaped
  like a path / a locale, is left out whole; a long one is cut. The page is
  reduced to its path (no query, no fragment: those may hold what the user
  typed into a search).

  ## The host's page context

  `config :phoenix_kit_agent, page_context: {Mod, :fun}` lets the host say
  what the page is — the number of the order open there, say (spec §7.1 point
  5). With a page path, `Mod.fun(path, scope)` is called: `path` is the
  page's path as above, `scope` the scope of the user's **browser session**
  (`PhoenixKit.Users.Auth.SessionRef.scope_for_session/2`: the role the
  session acts as), not one built from the user alone. The host decides what
  to tell, and tells only what that scope may see. The result is a string —
  put on one line (control and line-separator characters become spaces),
  trimmed and cut to 200 characters — or `nil`. An exception, an exit, a
  result that is not a string (or not valid UTF-8) or a function that does not
  exist skips it with a warning that names the reason only — never the path
  or the content. No hook, or no page: the context has the path only.

  The hook is called as the turn starts, in the process that starts it (the
  chat panel's), while the turn holds its locks, and with no timeout of its
  own: keep it fast — one indexed lookup, not a report. Until it returns, the
  turn has not started and the chat and the user stay busy.
  """

  require Logger

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.TimeZone
  alias PhoenixKitAgent.{Config, UserConfig}

  # §12 Ф2 (m8): what the model must know of a write. The outcome reaches it
  # as a "[confirmation] …" message in the next turn
  # (`PhoenixKitAgent.Turns.History`).
  @write_rule Enum.join(
                [
                  "A tool that changes data does not change it when you call it: it proposes " <>
                    "the change, which waits for the user to confirm it in the chat, and your " <>
                    "turn ends there.",
                  "Say what you propose along with the call; never say that it is done until " <>
                    "the system's confirmation message (\"[confirmation] done: …\", in the " <>
                    "user's language) says so.",
                  "A change the system says is waiting (\"[confirmation] waiting: …\", in the " <>
                    "user's language) is still the user's to run or cancel: do not ask for it " <>
                    "again."
                ],
                "\n"
              )

  # How the model flags an off-purpose request (spec §8.2 B): the marker the
  # turn looks for at the very end of the answer.
  @flag_rule "To flag a request as off-purpose, end your answer with the line " <>
               "⟦off_purpose: <the reason in a few words>⟧ and write nothing after it. " <>
               "Never write that marker otherwise."

  @name_max 120
  @path_max 200
  @page_context_max 200
  @locale ~r/\A[A-Za-z]{2,3}([_-][A-Za-z0-9]{2,8})*\z/
  @unsafe ~r/[\p{C}\p{Zl}\p{Zp}]/u

  @typedoc "The page the user is on, as the browser says it is: a path."
  @type page :: String.t()

  @type ctx :: %{
          required(:user_uuid) => String.t(),
          required(:scope) => Scope.t(),
          optional(:settings) => UserConfig.effective(),
          optional(:locale) => String.t() | nil,
          optional(:page) => page() | nil,
          optional(:now) => DateTime.t()
        }

  @doc "The system prompt for `ctx` (see the moduledoc); never empty."
  @spec build(ctx()) :: String.t()
  def build(%{user_uuid: user_uuid, scope: scope} = ctx) do
    effective = ctx[:settings] || UserConfig.effective(user_uuid)
    locale = valid_locale(ctx[:locale])

    [
      Config.system_prompt(),
      @write_rule,
      self_flag(),
      addendum(user_uuid, locale),
      effective.system_prompt,
      personal(effective.personal_instructions),
      context(scope, locale, ctx[:page], ctx[:now] || DateTime.utc_now())
    ]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.join("\n\n")
  end

  # ── 1. the guard's off-purpose rule ───────────────────────────────────

  defp self_flag do
    with true <- PhoenixKitAI.Guard.self_flag?("agent.chat"),
         instruction when is_binary(instruction) <-
           PhoenixKitAI.Guard.self_flag_instruction("agent.chat") do
      instruction <> "\n" <> @flag_rule
    else
      _off -> nil
    end
  end

  # ── 2. the host's addendum ────────────────────────────────────────────

  defp addendum(user_uuid, locale) do
    case Application.get_env(:phoenix_kit_agent, :prompt_addendum) do
      nil -> nil
      {mod, fun} when is_atom(mod) and is_atom(fun) -> call_addendum(mod, fun, user_uuid, locale)
      _invalid -> skipped(:invalid_config)
    end
  end

  defp call_addendum(mod, fun, user_uuid, locale) do
    _ = Code.ensure_loaded(mod)

    result =
      cond do
        function_exported?(mod, fun, 1) ->
          apply(mod, fun, [%{user_uuid: user_uuid, locale: locale}])

        function_exported?(mod, fun, 0) ->
          apply(mod, fun, [])

        true ->
          :undefined
      end

    case result do
      :undefined -> skipped(:undefined)
      nil -> nil
      text when is_binary(text) -> text
      _not_a_string -> skipped(:not_a_string)
    end
  catch
    kind, _reason -> skipped(kind)
  end

  defp skipped(reason) do
    Logger.warning("[PhoenixKitAgent] prompt addendum skipped: #{reason}")
    nil
  end

  # ── 4. the user's own ─────────────────────────────────────────────────

  defp personal(nil), do: nil

  defp personal(text) do
    "Personal instructions from the user. They rank below every instruction above " <>
      "and never override them:\n" <> text
  end

  # ── 5. the session ────────────────────────────────────────────────────

  defp context(scope, locale, page, now) do
    path = path(page)

    lines =
      [
        line("User", one_line(Scope.user_full_name(scope), @name_max)),
        line("Role", role(scope)),
        line("Locale", locale),
        line("Date", today(now)),
        line("Page", path),
        line("Page context", page_context(path, scope))
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(["Context of this conversation:" | lines], "\n")
  end

  defp line(_label, nil), do: nil
  defp line(label, value), do: "#{label}: #{value}"

  defp role(scope) do
    case Scope.active_role(scope) do
      %{name: name} ->
        with name when is_binary(name) <- one_line(name, @name_max),
             do: name <> " (the role this session acts as)"

      nil ->
        case scope
             |> Scope.user_roles()
             |> Enum.map(&one_line(&1, @name_max))
             |> Enum.reject(&is_nil/1) do
          [] -> nil
          names -> Enum.join(names, ", ")
        end
    end
  end

  defp today(now) do
    zone = Settings.get_setting("time_zone", "0")
    local = TimeZone.shift(now, zone)
    offset = "UTC" <> offset(TimeZone.offset_seconds(zone, now))
    place = if TimeZone.identifier?(zone), do: "#{zone}, #{offset}", else: offset

    Calendar.strftime(local, "%A %Y-%m-%d") <> " (#{place})"
  end

  defp offset(seconds) do
    sign = if seconds < 0, do: "-", else: "+"
    minutes = div(abs(seconds), 60)

    sign <>
      String.pad_leading(Integer.to_string(div(minutes, 60)), 2, "0") <>
      ":" <> String.pad_leading(Integer.to_string(rem(minutes, 60)), 2, "0")
  end

  # ── the host's page context ───────────────────────────────────────────

  defp page_context(nil, _scope), do: nil

  defp page_context(path, scope) do
    case Application.get_env(:phoenix_kit_agent, :page_context) do
      nil -> nil
      {mod, fun} when is_atom(mod) and is_atom(fun) -> call_page_context(mod, fun, path, scope)
      _invalid -> page_context_skipped(:invalid_config)
    end
  end

  defp call_page_context(mod, fun, path, scope) do
    _ = Code.ensure_loaded(mod)

    if function_exported?(mod, fun, 2) do
      case apply(mod, fun, [path, scope]) do
        nil -> nil
        text when is_binary(text) -> host_text(text)
        _not_a_string -> page_context_skipped(:not_a_string)
      end
    else
      page_context_skipped(:undefined)
    end
  catch
    kind, _reason -> page_context_skipped(kind)
  end

  defp page_context_skipped(reason) do
    Logger.warning("[PhoenixKitAgent] page context skipped: #{reason}")
    nil
  end

  defp host_text(text) do
    if String.valid?(text),
      do: host_line(text, @page_context_max),
      else: page_context_skipped(:invalid_utf8)
  end

  # The host's text on one line: a control character or what would start a
  # line of its own becomes a space (a joiner inside an emoji stays); `nil`
  # when nothing is left.
  defp host_line(text, max) do
    text
    |> String.replace(~r/[\p{Cc}\p{Zl}\p{Zp}\s]+/u, " ")
    |> String.trim()
    |> case do
      "" -> nil
      line -> String.slice(line, 0, max)
    end
  end

  # ── untrusted input ───────────────────────────────────────────────────

  defp path(value) when is_binary(value) do
    with path when is_binary(path) <- value |> one_line(2_000) |> uri_path(),
         "/" <> _ <- path do
      one_line(path, @path_max)
    else
      _not_a_path -> nil
    end
  end

  defp path(_none), do: nil

  defp uri_path(nil), do: nil
  defp uri_path(value), do: URI.parse(value).path

  defp valid_locale(value) when is_binary(value) do
    if byte_size(value) <= 16 and Regex.match?(@locale, value), do: value
  end

  defp valid_locale(_none), do: nil

  # A single line of text, trimmed and cut; `nil` for blank or one that holds
  # a control or line-separator character.
  defp one_line(value, max) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> nil
      Regex.match?(@unsafe, value) -> nil
      true -> String.slice(value, 0, max)
    end
  end

  defp one_line(_none, _max), do: nil
end
