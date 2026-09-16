# frozen_string_literal: true

module InappNotifications
  # Zápis jedného riadku notifikácie. Volá sa z `MailerPatch#mail`, teda pre každý
  # odoslaný mail — musí byť lacný a nesmie nikdy vyhodiť výnimku smerom von
  # (o to sa stará `rescue` v patchi, ale aj tu sa drží defenzívny štýl).
  module Capture
    module_function

    def record(call, message)
      return unless InappNotifications.enabled?
      return if call.nil?

      action, args = call
      return unless Events.known?(action)

      user = args[0]
      return if user.nil?
      return unless user.is_a?(User) && user.logged?

      # Kontrola `no_self_notified`: jadro autorove adresy z `to` odstránilo, ale samotné
      # volanie akcie prebehlo. Prienik s adresami užívateľa, nie `message.to.blank?` —
      # človek môže mať viac e-mailových adries a mail mohol ísť na inú než primárnu.
      return if (Array(message.to) & user.mails).empty?

      return write_reaction(user, args[1]) if action == Events::REACTION

      source = source_from(action, args[1])
      return if source.nil?

      write(user, action, source)
    end

    # `attachments_added` dostane pole príloh; ukladá sa prvá. Viď komentár
    # pri `Events::ATTACHMENTS` — kontajner by kolidoval s unique indexom.
    def source_from(action, arg)
      arg = arg.first if action == Events::ATTACHMENTS && arg.is_a?(Array)
      return nil if arg.nil? || !arg.respond_to?(:id) || arg.id.nil?

      # Ochrana pred tým, že by plugin niekedy poslal do známej akcie iný typ, než čakáme —
      # do DB by sa dostal `source_type`, ktorý loader nevie preložiť.
      return nil unless Events.source_types_for(action).include?(arg.class.name)

      arg
    end

    # Reakcie (👍) majú vlastnú cestu, lebo ich kľúčom nie je objekt, ktorý poslal mailer.
    #
    # Ukladá sa dvojica (objekt, kto lajkol) namiesto id reakcie — to sa pri každom
    # odlajkovaní a opätovnom lajknutí mení, takže prepínanie vyrábalo ďalšie a ďalšie
    # riadky. Na už existujúci riadok sa potom pozeráme takto:
    #
    #   * je v okne na zlučovanie → NEROBÍ SA NIČ. Človek o tom lajku už vie (alebo ho má
    #     medzi neprečítanými) a druhá notifikácia o tom istom je šum. Sem spadá aj to,
    #     keď niekto lajk stokrát vypne a zapne — zostane jediná notifikácia.
    #   * bol stiahnutý (odlajkované) a je v okne → len sa vráti späť, BEZ dotyku na
    #     `read_on`: keď ho už čítal, nech mu odznak nenaskočí druhý raz; keď nečítal,
    #     zostáva neprečítaný.
    #   * je starší než okno → berie sa to ako nová udalosť: nový čas, znova neprečítané.
    def write_reaction(user, reaction)
      target = reactable_of(reaction)
      return if target.nil?

      attrs = { :user_id     => user.id,
                :event       => Events::REACTION,
                :source_type => target.class.name,
                :source_id   => target.id,
                :actor_id    => reaction.user_id.to_i }

      existing = InappNotification.find_by(attrs)
      return create_row(attrs.merge(:project_id => project_id_for(target))) if existing.nil?

      if existing.created_on && existing.created_on > InappNotifications.merge_window.ago
        existing.update_columns(:retracted_on => nil) if existing.retracted_on
      else
        existing.update_columns(:created_on   => Time.current,
                                :read_on      => nil,
                                :retracted_on => nil)
      end

      existing
    end

    # Reakcia musí viesť na objekt z whitelistu — do `source_type` sa nesmie dostať nič,
    # čo loader nevie preložiť.
    def reactable_of(reaction)
      return nil unless reaction.respond_to?(:reactable) && reaction.respond_to?(:user_id)

      target = reaction.reactable
      return nil if target.nil? || target.id.nil?
      return nil unless Events::REACTABLES.include?(target.class.name)

      target
    end

    # Zápis beží vo VNORENEJ TRANSAKCII (SAVEPOINT) — `requires_new: true`.
    #
    # Bez toho je to reálna chyba, nie teoretická: v Postgrese porušenie unique indexu
    # zhodí CELÚ prebiehajúcu transakciu do stavu „aborted" a každý ďalší príkaz v nej
    # skončí na `PG::InFailedSqlTransaction`. Odchytenie výnimky v Ruby to nezachráni —
    # databáza už transakciu odpísala. Keď sa teda mail posiela synchrónne vnútri
    # transakcie (`Mailer.with_synched_deliveries`, hromadné operácie, rake tasky),
    # jedna duplicitná notifikácia by strhla so sebou celé uloženie.
    #
    # SAVEPOINT to ohraničí: rollback sa týka len tohto INSERT-u a volajúci pokračuje.
    def write(user, action, source)
      create_row(
        :user_id     => user.id,
        :event       => action,
        :source_type => source.class.name,
        :source_id   => source.id,
        :project_id  => project_id_for(source)
      )
    end

    def create_row(attrs)
      InappNotification.transaction(:requires_new => true) do
        InappNotification.create!(attrs.merge(:created_on => Time.current))
      end
    rescue ActiveRecord::RecordNotUnique
      # Opakovaný beh toho istého jobu (ActiveJob retry) alebo súbeh dvoch procesov.
      # Unique index je tu práve preto, aby to rozhodla databáza a nie súbeh dvoch SELECT-ov.
      # Platí to dvojnásobne pri reakciách, kde sa pred INSERT-om ešte pozeráme SELECT-om.
      nil
    end

    # Projekt sa hľadá len na upratovanie pri strate členstva, takže keď ho objekt nemá,
    # nie je to chyba — `nil` je platná hodnota.
    def project_id_for(source)
      return source.project_id if source.respond_to?(:project_id)
      return source.project&.id if source.respond_to?(:project)

      nil
    rescue StandardError
      nil
    end
  end
end
