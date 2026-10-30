defmodule PhoenixKitAgent.Web.Dock.Panel do
  @moduledoc """
  The markup of the chat panel (`PhoenixKitAgent.Web.Dock`) and its browser
  hooks: the button with the list of chats, and the panel with the feed, the
  indicator and the composer. The LiveView holds the state and the events;
  this module only draws them.

  The hooks are runtime colocated hooks (the host bundles nothing for them),
  and live here because a colocated hook is named after the module that
  renders the element using it. They run from inline `<script>` elements, so
  under a Content-Security-Policy the page must allow `script-src
  'unsafe-inline'`; the scripts carry no nonce. Without them the panel shows,
  but forgets its state, does not resize, and Enter does not send:

    * `.DockState` — keeps the panel open or closed, the chosen chat and the
      width in `localStorage`, and tells the LiveView on mount and when it
      joins again after a lost connection (`restore`): a re-join mounts the
      LiveView afresh, while the hook's element stays and gets no `mounted`;
    * `.Feed` — keeps the feed scrolled to its end while the user is there,
      also after a live navigation moves the view (it is hidden until pinned);
    * `.Composer` — Enter sends, the page's path goes with the form, the text
      is cleared once the turn started (`pk-agent:sent`). The textarea is
      `phx-update="ignore"`: the browser owns the draft, so a re-render (a
      file uploading, a message arriving) never wipes it;
    * `.Waiting` — the indicator gives up after the deadline of a turn and
      its grace period, counted again for each turn (`data-turn`) and after a
      lost connection is found again (`reconnected`).
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitAgent.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Input, only: [input: 1]
  import PhoenixKitWeb.Components.Core.ResumableUpload, only: [resumable_upload: 1]
  import PhoenixKitWeb.Components.Core.Textarea, only: [textarea: 1]
  import PhoenixKitAgent.Web.Dock.Components

  alias Phoenix.LiveView.JS
  alias PhoenixKitAgent.Web.Dock.Texts
  alias PhoenixKitWeb.Components.AdminDock

  @doc "The button, the list of chats and the panel."
  attr(:user_uuid, :string, required: true)
  attr(:chats, :list, required: true)
  attr(:next_cursor, :any, required: true)
  attr(:renaming, :string, default: nil)
  attr(:conversation, :any, required: true)
  attr(:messages, :any, required: true, doc: "the `:messages` stream")

  attr(:pinned, :list,
    default: [],
    doc: "the waiting cards of the chat older than the page in the feed"
  )

  attr(:earlier?, :boolean, required: true)
  attr(:activity, :any, required: true)
  attr(:timeout_ms, :integer, required: true)
  attr(:turn_ref, :string, default: nil)
  attr(:restored, :integer, default: 0, doc: "how many times the browser restored the panel")
  attr(:error, :string, default: nil)
  attr(:instructions_form, :any, default: nil)
  attr(:unsent, :list, required: true)
  attr(:upload, :any, required: true, doc: "`@uploads.files`")
  attr(:resumable, :map, required: true, doc: "`@resumable_uploads`")
  attr(:upload_context, :string, required: true, doc: "what a file picked now is for")

  def dock(assigns) do
    ~H"""
    <div
      id="pk-agent-dock"
      phx-hook=".DockState"
      data-storage-key={"pk-agent-dock:" <> @user_uuid}
      class="flex items-center"
    >
      <.hooks />
      <.chat_list
        chats={@chats}
        next_cursor={@next_cursor}
        renaming={@renaming}
        current={@conversation && @conversation.uuid}
      />

      <%!-- The panel: over the dock column from lg up, the whole screen below --%>
      <%!-- Focusable, so that choosing a chat moves the focus here and the
           list (open while it has the focus) closes --%>
      <section
        id="pk-agent-panel"
        tabindex="-1"
        data-conversation={@conversation && @conversation.uuid}
        data-restored={@restored}
        aria-label={gettext("AI assistant")}
        class={[
          "hidden [.pk-dock-open_&]:flex flex-col outline-none",
          "fixed top-16 bottom-0 right-0 z-40 w-[var(--pk-dock-width,25rem)]",
          "max-lg:left-0 max-lg:w-auto",
          "bg-base-100 border-l border-base-300 max-lg:border-l-0"
        ]}
      >
        <div
          data-pk-agent-resize
          class="hidden lg:block absolute left-0 top-0 bottom-0 w-1.5 -ml-0.5 cursor-col-resize hover:bg-primary/20 transition-colors"
          aria-hidden="true"
        >
        </div>

        <header class="flex items-center gap-2 border-b border-base-300 px-3 py-2">
          <.icon name="hero-sparkles" class="w-4 h-4 shrink-0 text-primary" />
          <h2 class="flex-1 truncate text-sm font-semibold">
            {if @conversation, do: chat_title(@conversation), else: gettext("AI assistant")}
          </h2>
          <button
            id="pk-agent-instructions-toggle"
            type="button"
            phx-click="toggle_instructions"
            class={["btn btn-ghost btn-xs btn-circle", @instructions_form && "btn-active"]}
            aria-label={gettext("Personal instructions")}
            title={gettext("Personal instructions")}
          >
            <.icon name="hero-adjustments-horizontal" class="w-4 h-4" />
          </button>
          <button
            id="pk-agent-close"
            type="button"
            phx-click={AdminDock.close() |> JS.push("panel_closed")}
            class="btn btn-ghost btn-xs btn-circle"
            aria-label={gettext("Close")}
            title={gettext("Close")}
          >
            <.icon name="hero-x-mark" class="w-4 h-4" />
          </button>
        </header>

        <.form
          :if={@instructions_form}
          for={@instructions_form}
          id="pk-agent-instructions-form"
          phx-submit="save_instructions"
          class="border-b border-base-300 p-3 space-y-2"
        >
          <p class="text-xs opacity-70">
            {gettext(
              "How the assistant should answer you. It follows the site's own rules first."
            )}
          </p>
          <.textarea
            field={@instructions_form[:personal_instructions]}
            rows="4"
            maxlength="4000"
            class="textarea-sm text-sm"
          />
          <div class="flex justify-end">
            <button type="submit" class="btn btn-primary btn-xs">{gettext("Save")}</button>
          </div>
        </.form>

        <div
          :if={@error}
          id="pk-agent-dock-error"
          role="alert"
          class="alert alert-soft alert-error m-3 mb-0 py-2 text-xs"
        >
          <.icon name="hero-exclamation-circle" class="w-4 h-4" />
          <span class="flex-1">{@error}</span>
          <button type="button" phx-click="dismiss_error" class="btn btn-ghost btn-xs btn-circle" aria-label={gettext("Close")}>
            <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
          </button>
        </div>

        <%!-- `style` belongs to `.Feed` (it hides the feed while it is being pinned to the end) --%>
        <div
          class="flex-1 min-h-0 overflow-y-auto px-3 py-3"
          id="pk-agent-feed-scroll"
          phx-hook=".Feed"
          phx-mounted={JS.ignore_attributes(["style"])}
          data-conversation={@conversation && @conversation.uuid}
          data-restored={@restored}
        >
          <div id="pk-agent-feed-content">
            <div :if={@earlier?} class="pb-3 text-center">
              <button id="pk-agent-earlier" type="button" phx-click="load_earlier" class="btn btn-ghost btn-xs">
                {gettext("Earlier messages")}
              </button>
            </div>
            <div :if={@pinned != []} id="pk-agent-pinned" class="space-y-3 pb-3">
              <.feed_message :for={message <- @pinned} id={"pk-agent-pinned-" <> message.uuid} message={message} />
            </div>
            <div id="pk-agent-feed" phx-update="stream" class="space-y-3">
              <div id="pk-agent-feed-empty" class="hidden only:block py-8 text-center text-xs opacity-60">
                {gettext("Ask about anything you can see in the system.")}
              </div>
              <.feed_message :for={{dom_id, message} <- @messages} id={dom_id} message={message} />
            </div>
          </div>
        </div>

        <div
          :if={@activity}
          id="pk-agent-waiting"
          phx-hook=".Waiting"
          phx-mounted={JS.ignore_attributes(["data-timed-out"])}
          data-timeout-ms={@timeout_ms}
          data-turn={@turn_ref}
          data-activity={activity_key(@activity)}
          class="group flex items-center gap-2 px-4 pb-2 text-xs opacity-70"
        >
          <span class="loading loading-dots loading-xs group-data-[timed-out=true]:hidden"></span>
          <span class="group-data-[timed-out=true]:hidden">{activity_text(@activity)}</span>
          <span class="hidden group-data-[timed-out=true]:inline text-warning">
            {gettext("No answer has come. Open the chat again to see where it stands.")}
          </span>
        </div>

        <.composer
          upload={@upload}
          resumable={@resumable}
          upload_context={@upload_context}
          user_uuid={@user_uuid}
          unsent={@unsent}
          turn_ref={@turn_ref}
          activity={@activity}
        />
      </section>
    </div>
    """
  end

  attr(:chats, :list, required: true)
  attr(:next_cursor, :any, required: true)
  attr(:renaming, :string, default: nil)
  attr(:current, :string, default: nil)

  defp chat_list(assigns) do
    ~H"""
    <div class="dropdown dropdown-end">
      <%!-- Not a <button>: Safari does not focus a clicked one, so the
           focus-based dropdown would never open (core's bell does the same) --%>
      <div
        id="pk-agent-dock-button"
        role="button"
        tabindex="0"
        phx-click="refresh_chats"
        class="btn btn-ghost btn-circle"
        aria-label={gettext("AI assistant")}
        title={gettext("AI assistant")}
      >
        <.icon name="hero-sparkles" class="w-5 h-5" />
      </div>
      <div
        id="pk-agent-chat-list"
        tabindex="0"
        class="dropdown-content z-[100] mt-3 w-80 max-w-[95vw] card bg-base-100 shadow-xl border border-base-200"
      >
        <div class="p-2">
          <button
            id="pk-agent-new-chat"
            type="button"
            phx-click={AdminDock.open() |> JS.push("new_chat") |> JS.focus(to: "#pk-agent-input")}
            class="btn btn-primary btn-sm w-full"
          >
            <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New chat")}
          </button>
        </div>
        <ul id="pk-agent-chats" class="menu menu-sm w-full max-h-96 overflow-y-auto flex-nowrap p-2 pt-0">
          <li :if={@chats == []} class="px-3 py-2 text-xs opacity-60">{gettext("No chats yet.")}</li>
          <li :for={chat <- @chats} id={"pk-agent-chat-#{chat.uuid}"} class="group">
            <%= if @renaming == chat.uuid do %>
              <form
                id={"pk-agent-rename-form-#{chat.uuid}"}
                phx-submit="rename_chat"
                class="flex items-center gap-1 px-1"
              >
                <input type="hidden" name="uuid" value={chat.uuid} />
                <.input
                  id={"pk-agent-rename-title-#{chat.uuid}"}
                  name="title"
                  value={chat.title}
                  maxlength="200"
                  class="input-xs"
                  wrapper_class="flex-1 min-w-0"
                  aria-label={gettext("Title")}
                  autofocus
                />
                <button type="submit" class="btn btn-xs btn-primary">{gettext("Save")}</button>
                <button type="button" phx-click="cancel_rename" class="btn btn-xs btn-ghost">
                  {gettext("Cancel")}
                </button>
              </form>
            <% else %>
              <div class={["flex items-center gap-1 pr-1", @current == chat.uuid && "menu-active"]}>
                <button
                  type="button"
                  data-role="open"
                  phx-click={
                    AdminDock.open()
                    |> JS.push("open_chat", value: %{uuid: chat.uuid})
                    |> JS.focus(to: "#pk-agent-panel")
                  }
                  class="flex-1 min-w-0 text-left"
                >
                  <span class="block truncate">{chat_title(chat)}</span>
                  <.chat_time id={"pk-agent-chat-time-#{chat.uuid}"} datetime={chat.last_message_at} />
                </button>
                <button
                  type="button"
                  id={"pk-agent-rename-#{chat.uuid}"}
                  phx-click="start_rename"
                  phx-value-uuid={chat.uuid}
                  class="btn btn-ghost btn-xs btn-circle opacity-60 hover:opacity-100"
                  aria-label={gettext("Rename")}
                  title={gettext("Rename")}
                >
                  <.icon name="hero-pencil" class="w-3.5 h-3.5" />
                </button>
                <button
                  type="button"
                  id={"pk-agent-archive-#{chat.uuid}"}
                  phx-click="archive_chat"
                  phx-value-uuid={chat.uuid}
                  class="btn btn-ghost btn-xs btn-circle opacity-60 hover:opacity-100"
                  aria-label={gettext("Archive")}
                  title={gettext("Archive")}
                >
                  <.icon name="hero-archive-box" class="w-3.5 h-3.5" />
                </button>
              </div>
            <% end %>
          </li>
        </ul>
        <div :if={@next_cursor} class="p-2 pt-0">
          <button id="pk-agent-more-chats" type="button" phx-click="more_chats" class="btn btn-ghost btn-xs w-full">
            {gettext("More")}
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr(:upload, :any, required: true)
  attr(:resumable, :map, required: true)
  attr(:upload_context, :string, required: true)
  attr(:user_uuid, :string, required: true)
  attr(:unsent, :list, required: true)
  attr(:turn_ref, :string, default: nil)
  attr(:activity, :any, required: true)

  defp composer(assigns) do
    ~H"""
    <form
      id="pk-agent-composer"
      phx-submit="send"
      phx-change="composer_change"
      class="border-t border-base-300 p-3 space-y-2"
    >
      <ul :if={@unsent != [] or @upload.entries != []} id="pk-agent-attachments" class="flex flex-wrap gap-1.5">
        <.attachment_chip :for={attachment <- @unsent} attachment={attachment} />
        <li
          :for={entry <- @upload.entries}
          id={"pk-agent-upload-#{entry.ref}"}
          class="flex items-center gap-2 rounded-box border border-base-300 px-2 py-1 text-xs"
        >
          <span class="truncate max-w-[10rem]">{entry.client_name}</span>
          <progress :if={entry.valid? and not entry.done?} class="progress progress-primary w-12" value={entry.progress} max="100"></progress>
          <span :if={entry.done?} class="loading loading-spinner loading-xs"></span>
          <span :for={err <- upload_errors(@upload, entry)} class="text-error">
            {Texts.upload_error(err)}
          </span>
          <%!-- A finished upload is with `Attachments.add/4` already: it is no longer the browser's to cancel --%>
          <button
            :if={not entry.done?}
            type="button"
            phx-click="cancel_upload"
            phx-value-ref={entry.ref}
            class="btn btn-ghost btn-xs btn-circle"
            aria-label={gettext("Cancel")}
          >
            <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
          </button>
        </li>
      </ul>
      <p :for={err <- upload_errors(@upload)} class="text-xs text-error">
        {Texts.upload_error(err)}
      </p>

      <input type="hidden" name="message[page]" value="" data-pk-agent-page />
      <%!-- A raw textarea: its hook owns its value (phx-update="ignore") --%>
      <textarea
        id="pk-agent-input"
        name="message[text]"
        phx-hook=".Composer"
        phx-update="ignore"
        phx-debounce="blur"
        rows="2"
        placeholder={gettext("Write a message…")}
        aria-label={gettext("Message")}
        class="textarea textarea-sm w-full resize-none text-sm"
      ></textarea>
      <.resumable_upload
        upload={@upload}
        resumable={@resumable}
        scope="agent-dock|files"
        context={@upload_context}
        user={@user_uuid}
      >
        <div class="flex items-center gap-2">
          <label
            for={@upload.ref}
            class="btn btn-ghost btn-sm btn-circle"
            aria-label={gettext("Attach a file")}
            title={gettext("Attach a file")}
          >
            <.icon name="hero-paper-clip" class="w-4 h-4" />
          </label>
          <.live_file_input upload={@upload} class="hidden" />
          <span class="flex-1"></span>
          <button
            :if={@turn_ref}
            id="pk-agent-stop"
            type="button"
            phx-click="stop"
            class="btn btn-sm btn-outline btn-error"
            disabled={@activity == :stopping}
          >
            <.icon name="hero-stop" class="w-4 h-4" /> {gettext("Stop")}
          </button>
          <%!-- Disabled while a lost upload is set to go on by itself --%>
          <button
            id="pk-agent-send"
            type="submit"
            class="btn btn-sm btn-primary"
            disabled={!!@turn_ref or @resumable.files.pending}
          >
            <.icon name="hero-paper-airplane" class="w-4 h-4" /> {gettext("Send")}
          </button>
        </div>
      </.resumable_upload>
    </form>
    """
  end

  defp hooks(assigns) do
    ~H"""
    <script :type={Phoenix.LiveView.ColocatedHook} name=".DockState" runtime>
      {
        mounted() {
          this.key = this.el.dataset.storageKey
          const state = this.read()
          // What the user chose, kept here: the class is on <body>, outside the
          // LiveView, and nothing else puts it back after a navigation.
          this.open = state.open === true
          this.width = typeof state.width === "number" ? this.clamp(state.width) : null
          this.apply()
          this.handleEvent("pk-agent:store", (patch) => this.write(patch))
          this.el.addEventListener("pointerdown", (event) => {
            const handle = event.target.closest("[data-pk-agent-resize]")
            if (handle) this.resize(event, handle)
          })
          this.el.addEventListener("click", (event) => {
            if (event.target.closest("#pk-agent-close")) this.open = false
          })
          this.onStop = () => this.apply()
          window.addEventListener("phx:page-loading-stop", this.onStop)
          this.restore()
        },
        updated() { this.apply() },
        reconnected() {
          this.apply()
          this.restore()
        },
        destroyed() {
          window.removeEventListener("phx:page-loading-stop", this.onStop)
        },
        apply() {
          if (this.width) document.body.style.setProperty("--pk-dock-width", this.width + "px")
          // Only ever adds: closing is the user's own act (the close button).
          if (this.open === true) document.body.classList.add("pk-dock-open")
        },
        restore() {
          const state = this.read()
          this.pushEvent("restore", {
            open: state.open === true,
            conversation_uuid: typeof state.conversation_uuid === "string" ? state.conversation_uuid : null
          })
        },
        read() {
          try {
            const value = JSON.parse(window.localStorage.getItem(this.key) || "{}")
            return value && typeof value === "object" ? value : {}
          } catch (_error) {
            return {}
          }
        },
        write(patch) {
          try {
            window.localStorage.setItem(this.key, JSON.stringify(Object.assign(this.read(), patch)))
          } catch (_error) {}
          if (typeof patch.open === "boolean") this.open = patch.open
          if (typeof patch.width === "number") this.width = patch.width
        },
        clamp(width) {
          const most = Math.max(320, Math.min(900, window.innerWidth - 360))
          return Math.round(Math.min(most, Math.max(320, width)))
        },
        resize(event, handle) {
          event.preventDefault()
          handle.setPointerCapture(event.pointerId)
          let width = null
          const move = (e) => {
            width = this.clamp(window.innerWidth - e.clientX)
            document.body.style.setProperty("--pk-dock-width", width + "px")
          }
          const up = () => {
            handle.removeEventListener("pointermove", move)
            handle.removeEventListener("pointerup", up)
            if (width) this.write({width: width})
          }
          handle.addEventListener("pointermove", move)
          handle.addEventListener("pointerup", up)
        }
      }
    </script>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Feed" runtime>
      {
        mounted() {
          this.stick = true
          this.navigating = false
          this.conversation = this.el.dataset.conversation || ""
          this.restored = this.el.dataset.restored || ""
          this.restoredOnce = false
          this.pin = () => { this.el.scrollTop = this.el.scrollHeight }
          // The feed is hidden (not removed) until it stands at its end, so
          // that no frame shows it at the top.
          this.hide()
          this.settle()
          this.el.addEventListener("scroll", () => {
            // A hidden panel (display: none) reports 0, and a sticky view that
            // is moved by a navigation is reset to 0: neither is the user.
            if (this.navigating || this.el.clientHeight === 0) return
            this.stick = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 48
          })
          this.observer = new MutationObserver(() => {
            if (this.stick) this.pin()
          })
          this.observer.observe(this.el, {childList: true, subtree: true})
          // The content, not only the scroller: a picture or a rendered card
          // that grows late must keep the end in view while the user is there.
          this.resizer = new ResizeObserver(() => {
            if (this.stick) this.pin()
          })
          this.resizer.observe(this.el)
          if (this.el.firstElementChild) this.resizer.observe(this.el.firstElementChild)
          this.onStart = (event) => {
            // Only a live navigation moves this view, and it resets the scroll.
            if (event.detail && event.detail.kind === "redirect") {
              this.navigating = true
              this.navStick = this.stick
              // If the stop never comes, the user's scrolling counts again.
              clearTimeout(this.navFailsafe)
              this.navFailsafe = setTimeout(() => { this.navigating = false }, 3000)
            }
          }
          this.onStop = () => {
            clearTimeout(this.navFailsafe)
            if (this.navigating && this.navStick) this.stick = true
            this.navigating = false
            if (this.stick) this.settle()
            else this.show()
          }
          window.addEventListener("phx:page-loading-start", this.onStart)
          window.addEventListener("phx:page-loading-stop", this.onStop)
        },
        updated() {
          // Another chat, or the first restore after the mount: start at the end.
          // Later restores (a re-join) leave a user who reads older messages be.
          const conversation = this.el.dataset.conversation || ""
          const restored = this.el.dataset.restored || ""
          const first = !this.restoredOnce && restored !== this.restored
          if (restored !== this.restored) this.restoredOnce = true
          const changed = conversation !== this.conversation
          this.conversation = conversation
          this.restored = restored
          if (changed || first) {
            this.stick = true
            this.hide()
            this.settle()
          } else if (this.stick) {
            this.pin()
          }
        },
        reconnected() {
          if (this.stick) this.pin()
        },
        destroyed() {
          window.removeEventListener("phx:page-loading-start", this.onStart)
          window.removeEventListener("phx:page-loading-stop", this.onStop)
          if (this.observer) this.observer.disconnect()
          if (this.resizer) this.resizer.disconnect()
          clearTimeout(this.failsafe)
          clearTimeout(this.navFailsafe)
        },
        hide() {
          this.el.style.visibility = "hidden"
          clearTimeout(this.failsafe)
          this.failsafe = setTimeout(() => this.show(), 1500)
        },
        show() {
          clearTimeout(this.failsafe)
          this.el.style.visibility = ""
        },
        settle() {
          this.pin()
          requestAnimationFrame(() => {
            this.pin()
            requestAnimationFrame(() => {
              this.pin()
              this.show()
            })
          })
        }
      }
    </script>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Composer" runtime>
      {
        mounted() {
          this.el.addEventListener("keydown", (event) => {
            if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
              event.preventDefault()
              if (this.el.form) this.el.form.requestSubmit()
            }
          })
          if (this.el.form) {
            this.el.form.addEventListener("submit", () => {
              const page = this.el.form.querySelector("[data-pk-agent-page]")
              if (page) page.value = window.location.pathname
            }, true)
          }
          this.handleEvent("pk-agent:sent", () => { this.el.value = "" })
        }
      }
    </script>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Waiting" runtime>
      {
        mounted() { this.arm() },
        updated() { this.arm() },
        reconnected() { this.arm() },
        destroyed() { clearTimeout(this.timer) },
        arm() {
          clearTimeout(this.timer)
          this.el.removeAttribute("data-timed-out")
          const ms = parseInt(this.el.dataset.timeoutMs, 10)
          if (ms > 0) this.timer = setTimeout(() => this.el.setAttribute("data-timed-out", "true"), ms)
        }
      }
    </script>
    """
  end

  defp chat_title(%{title: title}) when is_binary(title) and title != "", do: title
  defp chat_title(_conversation), do: gettext("New chat")

  defp activity_text(:stopping), do: gettext("Stopping…")

  defp activity_text({:tool, [_ | _] = names}),
    do: gettext("Calling a tool: %{names}…", names: Enum.join(names, ", "))

  defp activity_text({:tool, _none}), do: gettext("Calling a tool…")
  defp activity_text(_thinking), do: gettext("Thinking…")

  defp activity_key({:tool, _names}), do: "tool"
  defp activity_key(activity), do: to_string(activity)
end
