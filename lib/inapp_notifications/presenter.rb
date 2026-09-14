# frozen_string_literal: true

module InappNotifications
  # Prevod (notifikácia + zdrojový objekt) na to, čo sa reálne vykreslí v paneli.
  #
  # Väčšinu roboty spraví natívne `acts_as_event` — `event_title`, `event_description`,
  # `event_author`, `event_url` a `event_type` existujú na Issue, Journal, News, Message,
  # Document aj Attachment. Overené na živej inštancii; `event_url` navyše nesie kotvu
  # na konkrétny komentár, takže klik v paneli skočí presne naň.
  #
  # ŠTYRI TRIEDY `acts_as_event` NEMAJÚ (tiež overené): Comment, WikiContent, Reaction
  # a RemindMeReminder. Pre ne sú nižšie krátke adaptéry. Nie je to zbytočná abstrakcia —
  # jadro tie triedy jednoducho neimplementuje a bez adaptéra by panel na nich spadol.
  class Presenter
    # `statuses` = mapa `id => IssueStatus`, načítaná raz v Loaderi.
    #
    # PREČO TO TU JE (zmerané, nie predpokladané): `Journal#event_title` volá
    # `o.new_status`, čo je `IssueStatus.find_by_id(...)` na KAŽDÝ riadok. Nie je to
    # asociácia, takže `preload` naň nedosiahne, a `ActiveRecord::Base.cache` tiež nepomôže —
    # cachuje identické dotazy, ale každý stav má iné id. Pri 40 journaloch to bolo
    # **28 dotazov navyše** a počet rástol s dĺžkou zoznamu.
    #
    # Preto sa nadpis pre Journal skladá tu, z už preloadnutých dát. Formát je znak na znak
    # rovnaký ako v jadre (`journal.rb`), aby panel vyzeral ako zvyšok Redmine.
    def initialize(row, statuses: {})
      @n        = row.notification
      @source   = row.source
      @statuses = statuses
    end

    def to_h
      {
        :id      => @n.id,
        :event   => @n.event,
        :type    => icon_type,
        :title   => title,
        :snippet => snippet,
        :author  => author_name,
        :url     => url,
        :at      => @n.created_on&.iso8601,
        :unread  => !@n.read?
      }
    end

    private

    def adapter?
      %w[Comment WikiContent Reaction RemindMeReminder].include?(@n.source_type)
    end

    def title
      return adapter_title if adapter?
      return journal_title if @source.is_a?(Journal)

      safe { @source.event_title.to_s }
    end

    # Kópia formátu z jadra (`Journal#event_title`), ale bez `IssueStatus.find_by_id` —
    # stav sa berie z predpočítanej mapy. Viď komentár pri konštruktore.
    def journal_title
      issue = @source.issue
      return '' if issue.nil?

      status = status_from_details
      "#{issue.tracker} ##{issue.id}#{status ? " (#{status})" : nil}: #{issue.subject}"
    end

    def status_from_details
      detail = @source.details.detect { |d| d.prop_key == 'status_id' }
      return nil if detail.nil? || detail.value.blank?

      @statuses[detail.value.to_i]
    end

    def snippet
      text = if adapter?
               adapter_snippet
             else
               safe { @source.event_description.to_s }
             end
      text = text.to_s.strip.squeeze(" \n")
      text.length > 300 ? "#{text[0, 300]}…" : text
    end

    def author_name
      person = if adapter?
                 adapter_author
               else
                 safe { @source.event_author }
               end
      person.respond_to?(:name) ? person.name : person.to_s
    end

    def url
      return adapter_url if adapter?

      safe { @source.event_url } || {}
    end

    # Typ pre ikonu v paneli. Jadro vracia veci ako `issue-note`, `issue-closed`,
    # `issue-edit` — používa sa priamo, aby panel vyzeral ako zvyšok Redmine.
    def icon_type
      return @n.source_type.underscore.dasherize if adapter?
      # Aj `event_type` Journalu volá `new_status`, teda ďalší `IssueStatus.find_by_id`
      # na každý riadok — rovnaká pasca ako pri nadpise. Skladá sa preto tu, z mapy.
      return journal_type if @source.is_a?(Journal)

      safe { @source.event_type.to_s }.presence || @n.event.dasherize
    end

    # Doslovná kópia logiky z jadra (`journal.rb`, `acts_as_event :type`).
    def journal_type
      status = status_from_details
      return 'issue-note' if status.nil?

      status.is_closed? ? 'issue-closed' : 'issue-edit'
    end

    # --- adaptéry pre triedy bez acts_as_event -------------------------------

    def adapter_title
      case @source
      when Comment          then "#{@source.commented.try(:title)}"
      when WikiContent      then @source.page&.pretty_title.to_s
      when Reaction         then reaction_title
      when RemindMeReminder then @source.issue ? "#{@source.issue.tracker&.name} ##{@source.issue.id}: #{@source.issue.subject}" : ''
      else ''
      end
    end

    def adapter_snippet
      case @source
      when Comment          then @source.comments.to_s
      when WikiContent      then @source.text.to_s
      when Reaction         then ''
      when RemindMeReminder then @source.note.to_s
      else ''
      end
    end

    def adapter_author
      case @source
      when Comment          then @source.author
      when WikiContent      then @source.author
      when Reaction         then @source.user
      when RemindMeReminder then @source.user
      end
    end

    # URL logiku pre Comment už raz vyriešil `redmine_notify_reactions` — preberá sa,
    # aby sa obe miesta správali rovnako (komentár k novinke = kotva `message-<id>`).
    def adapter_url
      case @source
      when Comment
        { :controller => 'news', :action => 'show', :id => @source.commented_id,
          :anchor => "comment-#{@source.id}" }
      when WikiContent
        page = @source.page
        return {} if page.nil?

        { :controller => 'wiki', :action => 'show', :project_id => page.wiki&.project,
          :id => page.title }
      when Reaction
        reaction_url
      when RemindMeReminder
        @source.issue ? { :controller => 'issues', :action => 'show', :id => @source.issue_id } : {}
      else {}
      end
    end

    def reaction_title
      target = @source.reactable
      case target
      when Issue   then "#{target.tracker&.name} ##{target.id}: #{target.subject}"
      when Journal then target.issue ? "#{target.issue.tracker&.name} ##{target.issue.id}: #{target.issue.subject}" : ''
      else target.try(:title).to_s.presence || target.class.name
      end
    end

    def reaction_url
      target = @source.reactable
      case target
      when Issue   then { :controller => 'issues', :action => 'show', :id => target.id }
      when Journal then { :controller => 'issues', :action => 'show', :id => target.journalized_id,
                          :anchor => "change-#{target.id}" }
      else {}
      end
    end

    # Vykreslenie riadku nesmie zhodiť celý panel kvôli jednému čudnému objektu.
    def safe
      yield
    rescue StandardError => e
      Rails.logger&.warn("[inapp_notifications] presenter #{@n.source_type}##{@n.source_id}: #{e.class}")
      nil
    end
  end
end
