# frozen_string_literal: true

module InappNotifications
  class Hooks < Redmine::Hook::ViewListener
    # CSS + konfigurácia do hlavičky, JS na koniec stránky — rovnaký dvojhook vzor,
    # aký používa `redmine_command_palette` aj `redmine_ai_assistant`.
    def view_layouts_base_html_head(context = {})
      return '' unless InappNotifications.enabled?
      return '' unless User.current.logged?

      tags = stylesheet_link_tag('inapp_notifications', :plugin => 'redmine_inapp_notifications')
      tags + javascript_tag("window.RIN_CONFIG=#{config_json(context)};")
    end

    def view_layouts_base_body_bottom(context = {})
      return '' unless InappNotifications.enabled?
      return '' unless User.current.logged?

      javascript_include_tag('inapp_notifications', :plugin => 'redmine_inapp_notifications')
    end

    private

    # Počet neprečítaných ide rovno do stránky, nie ďalším requestom — odznak musí byť
    # správny hneď pri prvom vykreslení. Je to jeden COUNT nad partial indexom.
    def config_json(_context)
      {
        :base   => Redmine::Utils.relative_url_root.to_s,
        :unread => InappNotification.unread_count_for(User.current),
        :paths  => {
          :index   => '/inapp_notifications',
          :state   => '/inapp_notifications/state',
          :readAll => '/inapp_notifications/read_all'
        },
        # Panel stavia JS, takže texty nemá odkiaľ vziať z ERB.
        :i18n => {
          :title    => l(:'inapp_notifications.panel_title'),
          :empty    => l(:'inapp_notifications.panel_empty'),
          :loading  => l(:'inapp_notifications.panel_loading'),
          :error    => l(:'inapp_notifications.panel_error'),
          :readAll  => l(:'inapp_notifications.mark_all_read'),
          :seeAll   => l(:'inapp_notifications.see_all'),
          :settings => l(:'inapp_notifications.mail_settings'),
          :bell     => l(:'inapp_notifications.bell_label')
        }
      }.to_json.html_safe
    end
  end
end
