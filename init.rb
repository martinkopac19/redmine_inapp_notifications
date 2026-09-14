# frozen_string_literal: true

# Redmine In-app notifications (Previo) — zvonček v hlavičke s počtom neprečítaných
# a panelom so zoznamom.
#
# ROZSAH: in-app je DRUHÝ kanál vedľa mailu, nie náhrada. Maily bežia ďalej nezmenené
# a in-app dostane presne ten, kto by dostal mail (rozhodnutie zadávateľa, 11. 9. 2026).
#
# NA ČOM TO STOJÍ: záchyt je na `Mailer`, nie na modeloch — viď obsiahly komentár
# v `lib/inapp_notifications/mailer_patch.rb`. V skratke: jadro nemá centrálne miesto pre
# udalosti, ale má ho pre maily, a v tejto inštancii tri naše pluginy aktívne menia, komu
# mail ide. Odvodením od mailu sú in-app notifikácie z definície konzistentné a
# `redmine_notify_field_users`, `redmine_notification_filter`, `redmine_notify_reactions`
# ani `redmine_remind_me` sa nemusia dotknúť.
#
# `require_relative` je zámerne tu a nie v `to_prepare` — ten sa v production nespúšťa.
require_relative 'lib/inapp_notifications'
require_relative 'lib/inapp_notifications/events'
require_relative 'lib/inapp_notifications/capture'
require_relative 'lib/inapp_notifications/presenter'
require_relative 'lib/inapp_notifications/loader'
require_relative 'lib/inapp_notifications/mailer_patch'
require_relative 'lib/inapp_notifications/member_patch'
require_relative 'lib/inapp_notifications/hooks'

Redmine::Plugin.register :redmine_inapp_notifications do
  name 'In-app notifications (Previo)'
  author 'Martin Kopáč'
  description 'A bell in the header with unread count and a panel listing what would ' \
              'otherwise only arrive by e-mail. E-mail keeps working unchanged.'
  version '0.1.0'
  url 'https://github.com/martinkopac19/redmine_inapp_notifications'
  requires_redmine version_or_higher: '6.0'

  settings :default => InappNotifications::DEFAULTS,
           :partial => 'settings/inapp_notifications'

  # Do pravého horného rohu sa inak dostať nedá — pre hlavičku neexistuje žiadny view hook
  # a `account_menu` je jediné menu v tej oblasti, do ktorého sa dá pridať bez patchu layoutu.
  #
  # `url = '#'`, lebo položka otvára panel, nie stránku; JS klik zruší. Ikonka NEMÔŽE ísť
  # do `caption` — jadro ju prepúšťa cez `h(caption)` (menu_manager.rb:188), takže by sa
  # vypísala ako text. Rieši to CSS `::before` s data-URI, presne ako zvonček filtra mailov
  # a prútik AI asistenta. Triedu `.inapp-notifications` vyrobí jadro z názvu položky
  # (menu_manager.rb:459-460).
  menu :account_menu, :inapp_notifications, '#',
       :caption => :'inapp_notifications.bell_label',
       :before  => :my_account,
       # Triedu `.inapp-notifications` NEUVÁDZAME — jadro ju pridá samo z názvu položky
       # (`menu_manager.rb:459-460`). Keby sme ju napísali aj sem, bola by v HTML dvakrát.
       :html    => { 'data-rin' => 'bell' },
       :if      => proc { InappNotifications.enabled? && User.current.logged? }
end

unless Mailer.ancestors.include?(InappNotifications::MailerPatch)
  Mailer.prepend(InappNotifications::MailerPatch)
end

unless Member.included_modules.include?(InappNotifications::MemberPatch)
  Member.include(InappNotifications::MemberPatch)
end
