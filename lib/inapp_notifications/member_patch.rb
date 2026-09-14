# frozen_string_literal: true

module InappNotifications
  # Keď človeka vyhodia z projektu, jeho čakajúce notifikácie z toho projektu sa zmažú.
  #
  # Nie je to nutné pre správnosť — loader viditeľnosť kontroluje pri každom čítaní, takže
  # by sa také notifikácie aj tak nevykreslili. Ide o odznak: ten sa počíta surovým COUNT-om
  # bez kontroly práv (inak by každý render každej stránky načítaval objekty) a bez tohto
  # patchu by po odchode z projektu ukazoval číslo, ktoré panel nemá čím naplniť.
  #
  # Toto je jediný dôvod, prečo je `project_id` v tabuľke.
  module MemberPatch
    def self.included(base)
      base.after_destroy :inapp_notifications_cleanup
    end

    def inapp_notifications_cleanup
      return if user_id.blank? || project_id.blank?

      InappNotification.where(:user_id => user_id, :project_id => project_id).delete_all
    rescue StandardError => e
      # Odobratie člena nesmie zlyhať kvôli upratovaniu notifikácií.
      Rails.logger&.warn("[inapp_notifications] cleanup po odobrati clena: #{e.class}: #{e.message}")
    end
  end
end
