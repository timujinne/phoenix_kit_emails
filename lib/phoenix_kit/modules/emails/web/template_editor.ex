defmodule PhoenixKit.Modules.Emails.Web.TemplateEditor do
  @moduledoc """
  LiveView for creating and editing email templates in PhoenixKit admin panel.

  Provides a comprehensive template editor with live preview, variable management,
  test sending functionality, and template validation.

  ## Features

  - **Live Preview**: Real-time HTML and text preview with variable substitution
  - **Variable Management**: Define and validate template variables
  - **Template Validation**: Real-time validation of template content
  - **Test Send**: Send test emails using the template
  - **Version Control**: Track template versions and changes
  - **Syntax Highlighting**: Basic HTML syntax awareness

  ## Routes

  - `/admin/emails/templates/new` - Create new template
  - `/admin/emails/templates/:id/edit` - Edit existing template

  ## Permissions

  Access is restricted to users with admin or owner roles in PhoenixKit.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKit.Modules.Emails.Gettext
  import PhoenixKitWeb.Components.Core.Icon

  alias PhoenixKit.Modules.Emails.Template
  alias PhoenixKit.Modules.Emails.Templates
  alias PhoenixKit.Modules.Emails.TemplateSources
  alias PhoenixKit.Modules.Emails.Utils
  alias PhoenixKit.Modules.Emails.Web.SourceBadges
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes

  ## --- Lifecycle Callbacks ---

  @impl true
  def mount(_params, _session, socket) do
    # Get project title from settings

    available_locales = get_available_locales()
    default_locale = List.first(available_locales) || "en"

    socket =
      socket
      |> assign(:page_title, gettext("Email Template"))
      |> assign(:page_subtitle, gettext("Create and edit an email template"))
      |> assign(:template, nil)
      |> assign(:template_sources, TemplateSources.empty())
      |> assign(:mode, :new)
      |> assign(:loading, false)
      |> assign(:saving, false)
      |> assign(:changeset, Template.changeset(%Template{}, %{}))
      |> assign(:preview_mode, "html")
      |> assign(:show_test_modal, false)
      |> assign(:test_sending, false)
      |> assign(:test_form, %{recipient: "", sample_variables: %{}, errors: %{}})
      |> assign(:extracted_variables, [])
      |> assign(:available_locales, available_locales)
      |> assign(:current_editor_locale, default_locale)

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    case Templates.get_template(id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Template not found"))
         |> push_navigate(to: Routes.path("/admin/emails/templates"))}

      template ->
        changeset = Template.changeset(template, %{})
        extracted_variables = Template.extract_variables(template)

        socket =
          socket
          |> assign(
            :page_title,
            edit_title(template, socket.assigns[:current_editor_locale] || "en")
          )
          |> assign(:page_subtitle, template_subtitle(template))
          |> assign(:template, template)
          |> assign(:template_sources, TemplateSources.load())
          |> assign(:mode, :edit)
          |> assign(:changeset, changeset)
          |> assign(:extracted_variables, extracted_variables)

        {:noreply, socket}
    end
  end

  def handle_params(params, _url, socket) do
    # New template mode
    locale = socket.assigns[:current_editor_locale] || "en"

    initial_attrs = %{
      name: params["name"] || "",
      display_name: %{locale => Utils.string_param(params["display_name"])},
      category: params["category"] || "transactional",
      subject: %{},
      html_body: %{locale => default_html_template()},
      text_body: %{locale => default_text_template()},
      status: "draft",
      variables: %{}
    }

    changeset = Template.changeset(%Template{}, initial_attrs)

    socket =
      socket
      |> assign(:page_title, gettext("Create New Template"))
      |> assign(:page_subtitle, gettext("Create a new email template"))
      |> assign(:template, nil)
      |> assign(:mode, :new)
      |> assign(:changeset, changeset)
      |> assign(
        :extracted_variables,
        changeset |> Ecto.Changeset.apply_changes() |> Template.extract_variables()
      )

    {:noreply, socket}
  end

  ## --- Event Handlers ---

  @impl true
  def handle_event("validate", %{"email_template" => template_params}, socket)
      when is_map(template_params) do
    template = socket.assigns.template || %Template{}

    template_params =
      template_params
      |> drop_unrenderable_values()
      |> preserve_unsubmitted_translations(template)

    # Extract variables from current content
    temp_template = %Template{
      subject: template_params["subject"] || "",
      html_body: template_params["html_body"] || "",
      text_body: template_params["text_body"] || ""
    }

    extracted_variables = Template.extract_variables(temp_template)

    # Auto-add extracted variables with smart descriptions
    current_variables = template_params["variables"] || %{}

    # Convert string keys to ensure consistency
    current_variables =
      if is_map(current_variables) do
        current_variables
      else
        %{}
      end

    # Add any new extracted variables with smart descriptions
    updated_variables =
      Enum.reduce(extracted_variables, current_variables, fn var, acc ->
        if Map.has_key?(acc, var) do
          acc
        else
          Map.put(acc, var, "")
        end
      end)

    # Merge updated variables into template params
    template_params_with_vars = Map.put(template_params, "variables", updated_variables)

    changeset = Template.changeset(template, template_params_with_vars)

    socket =
      socket
      |> assign(:changeset, %{changeset | action: :validate})
      |> assign(:extracted_variables, extracted_variables)

    {:noreply, socket}
  end

  @impl true
  def handle_event("save", %{"email_template" => template_params, "save_as" => save_as}, socket)
      when is_map(template_params) do
    if non_string_translation?(template_params) do
      # validate drops such a value so the form can render; save must not —
      # dropping a crafted "en" => %{} would quietly save a new version with
      # no English at all.
      {:noreply,
       socket
       |> assign(:saving, false)
       |> put_flash(:error, gettext("Every translation must be text. Nothing was saved."))}
    else
      save_template(template_params, save_as, socket)
    end
  end

  @impl true
  def handle_event("save", %{"email_template" => template_params}, socket)
      when is_map(template_params) do
    # Default save without save_as parameter
    handle_event("save", %{"email_template" => template_params, "save_as" => "active"}, socket)
  end

  # A crafted event without a map under "email_template" has nothing to
  # validate or save; the form stays as it was.
  @impl true
  def handle_event(event, _params, socket) when event in ["validate", "save"] do
    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_preview", %{"mode" => mode}, socket) when mode in ["html", "text"] do
    {:noreply, assign(socket, :preview_mode, mode)}
  end

  @impl true
  def handle_event("switch_preview", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("switch_editor_locale", %{"locale" => locale}, socket) do
    available = socket.assigns.available_locales

    if locale in available do
      {:noreply,
       socket
       |> assign(:current_editor_locale, locale)
       |> refresh_page_title(locale)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("show_test_modal", _params, socket) do
    # Generate sample variables based on extracted variables
    sample_variables = generate_sample_variables(socket.assigns.extracted_variables)

    test_form = %{
      recipient: "",
      sample_variables: sample_variables,
      errors: %{}
    }

    {:noreply,
     socket
     |> assign(:show_test_modal, true)
     |> assign(:test_form, test_form)}
  end

  @impl true
  def handle_event("hide_test_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_test_modal, false)
     |> assign(:test_sending, false)
     |> assign(:test_form, %{recipient: "", sample_variables: %{}, errors: %{}})}
  end

  @impl true
  def handle_event("validate_test", params, socket) do
    test_params = test_params(params)
    errors = validate_test_form(test_params)

    sample_variables =
      sample_variables(test_params, socket.assigns.test_form.sample_variables)

    test_form = %{
      recipient: Utils.string_param(test_params["recipient"]),
      sample_variables: sample_variables,
      errors: errors
    }

    {:noreply, assign(socket, :test_form, test_form)}
  end

  @impl true
  def handle_event("send_test", params, socket) do
    test_params = test_params(params)
    errors = validate_test_form(test_params)

    if map_size(errors) == 0 do
      socket = assign(socket, :test_sending, true)

      # Get current template data from changeset
      changeset_data = Ecto.Changeset.apply_changes(socket.assigns.changeset)
      sample_variables = sample_variables(test_params, %{})

      # Send test email using the current editor locale
      locale = socket.assigns.current_editor_locale

      send(
        self(),
        {:send_test_email, test_params["recipient"], changeset_data, sample_variables, locale}
      )

      {:noreply, socket}
    else
      test_form = %{
        recipient: Utils.string_param(test_params["recipient"]),
        sample_variables: sample_variables(test_params, %{}),
        errors: errors
      }

      {:noreply, assign(socket, :test_form, test_form)}
    end
  end

  @impl true
  def handle_event(
        "update_variable_description",
        %{"name" => name, "value" => description},
        socket
      )
      when is_binary(name) and is_binary(description) do
    changeset = socket.assigns.changeset

    current_variables = Ecto.Changeset.get_field(changeset, :variables) || %{}
    updated_variables = Map.put(current_variables, name, description)

    updated_changeset = Ecto.Changeset.put_change(changeset, :variables, updated_variables)

    {:noreply, assign(socket, :changeset, updated_changeset)}
  end

  # A crafted name or description that is not a string would be rendered back
  # into the variables list (as an id and an input value) and raise there.
  @impl true
  def handle_event("update_variable_description", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("remove_variable", %{"name" => name}, socket) do
    changeset = socket.assigns.changeset

    current_variables = Ecto.Changeset.get_field(changeset, :variables) || %{}
    updated_variables = Map.delete(current_variables, name)

    updated_changeset = Ecto.Changeset.put_change(changeset, :variables, updated_variables)

    {:noreply, assign(socket, :changeset, updated_changeset)}
  end

  ## --- Info Handlers ---

  @impl true
  def handle_info({:send_test_email, recipient, template_data, sample_variables, locale}, socket) do
    # Create a temporary template for testing
    temp_template = %Template{
      name: template_data.name || "test_template",
      subject: template_data.subject || %{},
      html_body: template_data.html_body || %{},
      text_body: template_data.text_body || %{}
    }

    # Render template with sample variables in the current editor locale
    rendered = Templates.render_template(temp_template, sample_variables, locale)

    # Use PhoenixKit.Mailer to send test email
    email =
      Swoosh.Email.new()
      |> Swoosh.Email.to(recipient)
      |> Swoosh.Email.from({"PhoenixKit Test", get_from_email()})
      |> Swoosh.Email.subject("[TEST] #{rendered.subject}")
      |> Swoosh.Email.html_body(rendered.html_body)
      |> Swoosh.Email.text_body(rendered.text_body)

    # skip_queue: the flash below reports the outcome, so the send must be the
    # real one — a queued test would report success before anything was sent.
    case PhoenixKit.Mailer.deliver_email(email,
           template_name: temp_template.name,
           campaign_id: "template_test",
           skip_queue: true
         ) do
      {:ok, _email} ->
        {:noreply,
         socket
         |> assign(:test_sending, false)
         |> assign(:show_test_modal, false)
         |> put_flash(
           :info,
           gettext("Test email sent successfully to %{recipient}", recipient: recipient)
         )}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:test_sending, false)
         |> put_flash(
           :error,
           gettext("Failed to send test email: %{reason}", reason: inspect(reason))
         )}
    end
  rescue
    error ->
      {:noreply,
       socket
       |> assign(:test_sending, false)
       |> put_flash(
         :error,
         gettext("Error sending test email: %{message}", message: Exception.message(error))
       )}
  end

  ## --- Private Helper Functions ---

  # A system template's status changes only through the Templates list
  # page's Archive/Activate confirmation flow, which warns what archiving
  # does — this editor's Status select has no such warning, so for a system
  # row it must not be able to change status at all. Enforced server-side,
  # not just by disabling the select in the template: a crafted "save" event
  # could otherwise still submit it.
  defp protect_system_status(%Template{is_system: true}, template_params) do
    Map.delete(template_params, "status")
  end

  defp protect_system_status(_template, template_params), do: template_params

  # Who is saving, from the session — never from the form (see
  # `Templates.create_template/2`).
  defp current_user_uuid(socket), do: Scope.user_uuid(socket.assigns[:phoenix_kit_current_scope])

  defp create_template(socket, template_params) do
    case Templates.create_template(template_params,
           created_by_user_uuid: current_user_uuid(socket)
         ) do
      {:ok, template} ->
        {:noreply,
         socket
         |> assign(:saving, false)
         |> put_flash(
           :info,
           gettext("Template '%{name}' created successfully", name: template.name)
         )
         |> push_navigate(to: Routes.path("/admin/emails/templates"))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:saving, false)
         |> assign(:changeset, changeset)}
    end
  end

  defp update_template(socket, template_params) do
    case Templates.update_template(socket.assigns.template, template_params,
           updated_by_user_uuid: current_user_uuid(socket)
         ) do
      {:ok, template} ->
        {:noreply,
         socket
         |> assign(:saving, false)
         |> assign(:template, template)
         |> assign(:changeset, Template.changeset(template, %{}))
         |> assign(:extracted_variables, Template.extract_variables(template))
         |> assign(
           :page_title,
           edit_title(template, socket.assigns[:current_editor_locale] || "en")
         )
         |> assign(:page_subtitle, template_subtitle(template))
         |> assign(:template_sources, TemplateSources.load())
         |> put_flash(
           :info,
           gettext("Template '%{name}' updated successfully (v%{version})",
             name: template.name,
             version: template.version
           )
         )}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:saving, false)
         |> assign(:changeset, changeset)}
    end
  end

  # What the author is told a variable is for, shown as the description
  # field's placeholder while no description is stored. Never written to the
  # row: a stored description is the author's own text, and a hint saved in
  # the editor's language would stay in it whatever language reads it later.
  defp variable_hint("user_name"), do: gettext("User's display name")
  defp variable_hint("user_email"), do: gettext("User's email address")
  defp variable_hint("email"), do: gettext("User's email address")
  defp variable_hint("url"), do: gettext("Action URL or link")
  defp variable_hint("confirmation_url"), do: gettext("Email confirmation link")
  defp variable_hint("reset_url"), do: gettext("Password reset link")
  defp variable_hint("magic_link_url"), do: gettext("Magic link authentication URL")
  defp variable_hint("update_url"), do: gettext("Profile update URL")
  defp variable_hint("timestamp"), do: gettext("Current timestamp")
  defp variable_hint("app_name"), do: gettext("Application name")
  defp variable_hint("company_name"), do: gettext("Company or organization name")
  defp variable_hint("support_email"), do: gettext("Support contact email")
  defp variable_hint("first_name"), do: gettext("User's first name")
  defp variable_hint("last_name"), do: gettext("User's last name")
  defp variable_hint("username"), do: gettext("User's username")
  defp variable_hint("token"), do: gettext("Verification or authentication token")
  defp variable_hint("code"), do: gettext("Verification code")
  defp variable_hint("expiry"), do: gettext("Expiration date/time")
  defp variable_hint("subject"), do: gettext("Email subject line")
  defp variable_hint(name), do: gettext("Custom variable: %{name}", name: name)

  defp edit_title(template, locale) do
    gettext("Edit Template: %{name}",
      name: Template.get_translation(template.display_name, locale)
    )
  end

  defp template_subtitle(template) do
    gettext("Version %{version} • %{category} • %{source_module} • %{status}",
      version: template.version,
      category: category_label(template.category),
      source_module: source_module_label(Template.get_source_module(template)),
      status: status_label(template.status)
    )
  end

  defp refresh_page_title(
         %{assigns: %{template: %Template{} = template}} = socket,
         locale
       ),
       do: assign(socket, :page_title, edit_title(template, locale))

  defp refresh_page_title(socket, _locale), do: socket

  # The page subtitle names a template's category, status and source module;
  # the labels are the ones the editor's own selects show. A value the editor
  # has no label for is shown as it is stored.
  defp category_label("transactional"), do: gettext("Transactional")
  defp category_label("marketing"), do: gettext("Marketing")
  defp category_label("system"), do: gettext("System")
  defp category_label("notification"), do: gettext("Notification")
  defp category_label("newsletters"), do: gettext("Newsletters")
  defp category_label(other), do: other |> to_string() |> String.capitalize()

  defp status_label("draft"), do: gettext("Draft")
  defp status_label("active"), do: gettext("Active")
  defp status_label("archived"), do: gettext("Archived")
  defp status_label(other), do: other |> to_string() |> String.capitalize()

  defp source_module_label("users"), do: gettext("Users")
  defp source_module_label("billing"), do: gettext("Billing")
  defp source_module_label("publishing"), do: gettext("Publishing")
  defp source_module_label("entities"), do: gettext("Entities")
  defp source_module_label("admin"), do: gettext("Admin")
  defp source_module_label("custom"), do: gettext("Custom")
  defp source_module_label(other), do: other |> to_string() |> String.capitalize()

  # The preview: the template as edited so far, in the tab's language, with a
  # sample value for each variable it uses. Built from the changeset, so it
  # follows what is typed and not only what is saved.
  @doc false
  @spec preview(Ecto.Changeset.t(), String.t()) :: %{
          subject: String.t(),
          html_body: String.t(),
          text_body: String.t()
        }
  def preview(%Ecto.Changeset{} = changeset, locale) do
    template = Ecto.Changeset.apply_changes(changeset)

    variables =
      template
      |> Template.extract_variables()
      |> generate_sample_variables()

    Template.substitute_variables(template, variables, locale)
  end

  defp generate_sample_variables(variables) do
    Enum.into(variables, %{}, fn variable ->
      {variable, get_sample_value_for_variable(variable)}
    end)
  end

  defp get_sample_value_for_variable(variable) do
    sample_data = %{
      "user_name" => "John Doe",
      "user_email" => "john@example.com",
      "email" => "john@example.com",
      "url" => "https://example.com/action",
      "confirmation_url" => "https://example.com/confirm",
      "reset_url" => "https://example.com/reset",
      "magic_link_url" => "https://example.com/magic",
      "update_url" => "https://example.com/update",
      "timestamp" => UtilsDate.utc_now() |> DateTime.to_string(),
      "app_name" => PhoenixKit.Config.get(:project_title, "PhoenixKit"),
      "company_name" => "Your Company",
      "support_email" => "support@example.com"
    }

    Map.get(sample_data, variable, "Sample #{variable}")
  end

  # The test form's payload as a map. A crafted event can send a string, list
  # or number under "test", and reading keys from that raises.
  defp test_params(%{"test" => test_params}) when is_map(test_params), do: test_params
  defp test_params(_params), do: %{}

  # Sample variables go to Templates.render_template/3 and back into the form's
  # inputs, so only string names with string values are kept; a crafted
  # non-map falls back to `default`.
  defp sample_variables(%{"sample_variables" => vars}, _default) when is_map(vars),
    do: string_entries(vars)

  defp sample_variables(_test_params, default), do: default

  # The i18n fields and the variable descriptions are rendered back into the
  # editor's inputs, and the i18n values are also scanned for {{variables}}.
  # A crafted value that is not a string (a nested map, a list, a number)
  # raises in both, so it is dropped here, before either sees it.
  @i18n_fields ~w(display_name description subject html_body text_body)

  defp drop_unrenderable_values(template_params) do
    Enum.reduce(["variables" | @i18n_fields], template_params, fn field, acc ->
      case acc do
        %{^field => map} when is_map(map) -> Map.put(acc, field, string_entries(map))
        _ -> acc
      end
    end)
  end

  defp string_entries(map), do: Map.filter(map, fn {k, v} -> is_binary(k) and is_binary(v) end)

  # Only enabled languages have form controls. A missing locale must survive
  # validation and saving; a submitted empty value still removes that locale.
  # Keep this editor-specific: context callers can replace a whole locale map.
  defp preserve_unsubmitted_translations(params, %Template{} = template) do
    Enum.reduce(@i18n_fields, params, fn field, acc ->
      case acc do
        %{^field => submitted} when is_map(submitted) ->
          stored = Map.get(template, String.to_existing_atom(field)) || %{}
          Map.put(acc, field, Map.merge(stored, submitted))

        _ ->
          acc
      end
    end)
  end

  defp save_template(template_params, save_as, socket) do
    template_params =
      template_params
      |> drop_unrenderable_values()
      |> preserve_unsubmitted_translations(socket.assigns.template || %Template{})

    socket = assign(socket, :saving, true)

    # Extract variables and auto-add them before saving
    temp_template = %Template{
      subject: template_params["subject"] || "",
      html_body: template_params["html_body"] || "",
      text_body: template_params["text_body"] || ""
    }

    extracted_variables = Template.extract_variables(temp_template)

    # Auto-add extracted variables with smart descriptions
    current_variables = template_params["variables"] || %{}

    current_variables =
      if is_map(current_variables) do
        current_variables
      else
        %{}
      end

    updated_variables =
      Enum.reduce(extracted_variables, current_variables, fn var, acc ->
        if Map.has_key?(acc, var) do
          acc
        else
          Map.put(acc, var, "")
        end
      end)

    template_params_with_vars = Map.put(template_params, "variables", updated_variables)

    # Override status if saving as draft
    template_params_final =
      if save_as == "draft" do
        Map.put(template_params_with_vars, "status", "draft")
      else
        template_params_with_vars
      end

    try do
      case socket.assigns.mode do
        :new ->
          create_template(socket, template_params_final)

        :edit ->
          update_template(
            socket,
            protect_system_status(socket.assigns.template, template_params_final)
          )
      end
    rescue
      e ->
        require Logger
        Logger.error("Template save failed: #{Exception.message(e)}")

        {:noreply,
         socket
         |> assign(:saving, false)
         |> put_flash(:error, gettext("Something went wrong. Please try again."))}
    end
  end

  defp non_string_translation?(template_params) do
    Enum.any?(@i18n_fields, fn field ->
      case template_params[field] do
        map when is_map(map) -> Enum.any?(map, fn {_locale, value} -> not is_binary(value) end)
        _ -> false
      end
    end)
  end

  defp validate_test_form(params) do
    errors = %{}

    # Validate recipient email
    errors =
      case String.trim(Utils.string_param(params["recipient"])) do
        "" ->
          Map.put(errors, :recipient, gettext("Email address is required"))

        email ->
          if Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, email) do
            errors
          else
            Map.put(errors, :recipient, gettext("Please enter a valid email address"))
          end
      end

    errors
  end

  # Get the from email address from configuration or use a default
  # Priority: Settings Database > Config file > Default
  defp get_from_email do
    # Priority 1: Settings Database (runtime)
    case PhoenixKit.Settings.get_setting("from_email") do
      nil ->
        # Priority 2: Config file (compile-time, fallback)
        case PhoenixKit.Config.get(:from_email) do
          {:ok, email} -> email
          # Priority 3: Default
          _ -> "noreply@localhost"
        end

      email ->
        email
    end
  end

  defp default_html_template do
    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>{{subject}}</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; line-height: 1.6; color: #333; }
        .header { text-align: center; margin-bottom: 30px; }
        .button { display: inline-block; padding: 12px 24px; background-color: #3b82f6; color: white; text-decoration: none; border-radius: 6px; font-weight: 500; }
        .button:hover { background-color: #2563eb; }
        .footer { margin-top: 30px; padding-top: 20px; border-top: 1px solid #e5e7eb; font-size: 14px; color: #6b7280; }
      </style>
    </head>
    <body>
      <div class="container">
        <div class="header">
          <h1>Your email title here</h1>
        </div>

        <p>Hello {{user_name}},</p>

        <p>Your email content goes here...</p>

        <p style="text-align: center; margin: 30px 0;">
          <a href="{{url}}" class="button">Call to Action</a>
        </p>

        <div class="footer">
          <p>Thank you for using our service!</p>
        </div>
      </div>
    </body>
    </html>
    """
  end

  defp default_text_template do
    """
    Hello {{user_name}},

    Your email content goes here...

    {{url}}

    Thank you for using our service!
    """
  end

  # Returns the list of enabled locale codes for the editor tab bar.
  # Falls back to [content_language] if the Languages module is not active.
  defp get_available_locales do
    if function_exported?(Languages, :enabled?, 0) and Languages.enabled?() do
      Languages.get_enabled_language_codes()
    else
      [Settings.get_content_language() || "en"]
    end
  end
end
