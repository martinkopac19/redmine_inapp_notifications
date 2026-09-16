# frozen_string_literal: true

module InappNotifications
  # Odobratie lajku musí notifikáciu stiahnuť OKAMŽITE.
  #
  # Bez toho zostane riadok visieť a odznak ho počíta, kým ho otvorenie panelu nezahodí —
  # presne to bol prípad „34 na zvončeku, 2 v zozname". Panel si totiž mŕtve riadky
  # odfiltruje sám (a rovno ich zmaže), ale odznak je surový COUNT a k zdrojovým objektom
  # sa vôbec nepozerá; robiť to na každom renderi každej stránky by bolo neúnosné.
  #
  # Riadok sa NEMAŽE, len označí ako stiahnutý. Vďaka tomu vie `Capture#write_reaction`
  # pri opätovnom lajku do okna použiť ten istý záznam a nevyrobiť druhú notifikáciu
  # o tom istom. Domazávanie zostáva na retencii.
  module ReactionPatch
    def self.included(base)
      base.class_eval do
        after_destroy :rin_retract_notifications
      end
    end

    private

    def rin_retract_notifications
      return if reactable_type.blank? || reactable_id.blank?

      InappNotification.where(
        :event        => Events::REACTION,
        :source_type  => reactable_type,
        :source_id    => reactable_id,
        :actor_id     => user_id,
        :retracted_on => nil
      ).update_all(:retracted_on => Time.current)
    rescue StandardError => e
      # Notifikácia je bonus — nesmie zhodiť odobratie lajku.
      Rails.logger&.error("[inapp_notifications] stiahnutie reakcie zlyhalo: #{e.class}: #{e.message}")
    end
  end
end
