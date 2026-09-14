# frozen_string_literal: true

module InappNotifications
  DEFAULTS = {
    'enabled'        => '1',
    # Koľko riadkov ukáže panel. Plná stránka má stránkovanie a nie je tým obmedzená.
    'panel_limit'    => '20',
    # Retencia. Prečítané zmiznú skôr — už splnili účel.
    'keep_read_days' => '30',
    'keep_all_days'  => '180',
    # Lazy purge: upratovanie sa spustí najviac raz za deň, v requeste, ktorý práve
    # renderuje panel. Zámerne bez cronu — cron je ďalšia vec, ktorá sa dá zabudnúť
    # nastaviť pri sťahovaní na ďalší server (`redmine_remind_me` to odniesol).
    'lazy_purge'     => '1'
  }.freeze

  class << self
    def settings
      stored = Setting.plugin_redmine_inapp_notifications || {}
      DEFAULTS.merge(stored.to_h.reject { |_k, v| v.nil? || v.to_s.empty? })
    rescue StandardError
      DEFAULTS.dup
    end

    def setting(key)
      settings[key.to_s]
    end

    def enabled?
      setting('enabled').to_s == '1'
    end

    def panel_limit
      n = setting('panel_limit').to_i
      n <= 0 ? 20 : n.clamp(5, 100)
    end

    def keep_read_days
      n = setting('keep_read_days').to_i
      n <= 0 ? 30 : n
    end

    def keep_all_days
      n = setting('keep_all_days').to_i
      n <= 0 ? 180 : n
    end

    def lazy_purge?
      setting('lazy_purge').to_s == '1'
    end

    # Zmaže, čo už nikto nepotrebuje. Dva indexované DELETE-y, nič viac.
    def purge!
      now = Time.current
      InappNotification.where.not(:read_on => nil)
                       .where('created_on < ?', now - keep_read_days.days).delete_all
      InappNotification.where('created_on < ?', now - keep_all_days.days).delete_all
    end

    # Upratovanie sa spúšťa z requestu, ktorý renderuje panel — bez cronu a ZÁMERNE BEZ
    # ULOŽENÉHO ČASU POSLEDNÉHO BEHU.
    #
    # Pôvodný nápad bol zapisovať si časovú značku do `Setting`, lenže Redmine validuje názvy
    # nastavení proti registrovanému zoznamu (`setting.rb:95`), takže vlastný kľúč sa ticho
    # neuloží. Namiesto stavu sa teda pýtame priamo dát: „existuje vôbec niečo na zmazanie?"
    # Ten dotaz je nad indexom `created_on` a po prvom upratovaní nevráti nič, takže sa DELETE
    # nespustí znova, kým zase niečo nezostarne. Menej pohyblivých častí než časová značka.
    def purge_if_due!
      return unless lazy_purge?
      return unless stale_rows?

      purge!
    rescue StandardError => e
      Rails.logger&.warn("[inapp_notifications] purge preskoceny: #{e.class}: #{e.message}")
    end

    def stale_rows?
      now = Time.current
      InappNotification
        .where('created_on < ?', now - keep_all_days.days)
        .or(InappNotification.where.not(:read_on => nil)
                             .where('created_on < ?', now - keep_read_days.days))
        .exists?
    end
  end
end
