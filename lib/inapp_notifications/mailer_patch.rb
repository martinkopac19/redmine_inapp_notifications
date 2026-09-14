# frozen_string_literal: true

module InappNotifications
  # ZÁCHYT UDALOSTI NA MAILERI — nie na modeloch.
  #
  # Jadro nemá jedno miesto, kde by vznikala „udalosť, o ktorej sa notifikuje": sú to
  # roztrúsené `after_create_commit` callbacky na Issue, Journal, News, Message, Document,
  # WikiContent a k tomu dva controllery pre prílohy. Má však jedno miesto, kadiaľ prejde
  # KAŽDÝ notifikačný mail — a `Mailer#process` (mailer.rb:41-59) navyše vynucuje, že prvý
  # argument každej akcie je príjemca (`User`). Dostávame teda dvojicu (komu, o čom) zadarmo.
  #
  # PREČO TO JE DÔLEŽITEJŠIE, NEŽ SA ZDÁ: v tejto inštancii tri naše pluginy aktívne menia,
  # komu mail ide — `redmine_notify_field_users` pridáva ľudí z polí Tester/PM/Code review,
  # `redmine_notification_filter` niektorých odfiltruje podľa prechodu stavu. Keby sme si
  # zoznam príjemcov počítali sami, in-app notifikácie by sa s mailmi rozišli. Takto sú
  # z definície rovnaké a v tých pluginoch sa nemení ani riadok.
  #
  # Záchyt je rozdelený na dva body, a to zámerne — viď komentáre pri metódach.
  module MailerPatch
    def process(action, *args)
      # Len si odložíme tvar volania. Žiadna logika, žiadny dotaz, žiadne riziko —
      # `process` beží pri každom maile a nesmie byť miestom, kde sa dá niečo pokaziť.
      @inapp_call = [action.to_s, args]
      super
    end

    def mail(headers = {}, &block)
      message = super

      # Rozhodnutie „zapísať / nezapísať" musí padnúť AŽ TU, po `super`.
      #
      # Dôvod: `no_self_notified` (predvoľba „nechcem maily o vlastných zmenách") sa
      # v jadre aplikuje až vnútri `Mailer#mail`, na riadkoch mailer.rb:711-715 — odstráni
      # autorove adresy z `to`/`cc`. Keby sme sa rozhodovali v `process`, autor by dostal
      # in-app notifikáciu o vlastnej zmene, hoci mail mu zámerne neprišiel.
      begin
        InappNotifications::Capture.record(@inapp_call, message)
      rescue StandardError => e
        # Notifikácia je bonus. Keby na nej spadol mail, spôsobili by sme väčšiu škodu,
        # než akú riešime — mail je stále primárny kanál.
        Rails.logger&.error("[inapp_notifications] zachyt zlyhal: #{e.class}: #{e.message}")
      end

      message
    end
  end
end
