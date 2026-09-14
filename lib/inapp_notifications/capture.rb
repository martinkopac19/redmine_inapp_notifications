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

      user   = args[0]
      source = source_from(action, args[1])
      return if user.nil? || source.nil?
      return unless user.is_a?(User) && user.logged?

      # Kontrola `no_self_notified`: jadro autorove adresy z `to` odstránilo, ale samotné
      # volanie akcie prebehlo. Prienik s adresami užívateľa, nie `message.to.blank?` —
      # človek môže mať viac e-mailových adries a mail mohol ísť na inú než primárnu.
      return if (Array(message.to) & user.mails).empty?

      write(user, action, source)
    end

    # `attachments_added` dostane pole príloh; ukladá sa prvá. Viď komentár
    # pri `Events::ATTACHMENTS` — kontajner by kolidoval s unique indexom.
    def source_from(action, arg)
      arg = arg.first if action == Events::ATTACHMENTS && arg.is_a?(Array)
      return nil if arg.nil? || !arg.respond_to?(:id) || arg.id.nil?

      expected = Events.source_type_for(action)
      # Ochrana pred tým, že by plugin niekedy poslal do známej akcie iný typ, než čakáme —
      # do DB by sa dostal `source_type`, ktorý loader nevie preložiť.
      return nil unless arg.class.name == expected

      arg
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
      InappNotification.transaction(:requires_new => true) do
        InappNotification.create!(
          :user_id     => user.id,
          :event       => action,
          :source_type => source.class.name,
          :source_id   => source.id,
          :project_id  => project_id_for(source),
          :created_on  => Time.current
        )
      end
    rescue ActiveRecord::RecordNotUnique
      # Opakovaný beh toho istého jobu (ActiveJob retry) alebo súbeh dvoch procesov.
      # Unique index je tu práve preto, aby to rozhodla databáza a nie súbeh dvoch SELECT-ov.
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
