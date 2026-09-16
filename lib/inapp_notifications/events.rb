# frozen_string_literal: true

module InappNotifications
  # WHITELIST udalostí — jediné miesto, kde je napísané, čo je notifikácia.
  #
  # Je to biela listina, nie čierna, a to zámerne: neznáma akcia mailera sa ticho preskočí.
  # Tým sú `lost_password`, `security_notification`, `test_email`, `register`, `account_*`
  # a `settings_updated` vylúčené bez toho, aby sme ich museli menovať — a keď Redmine
  # v budúcej verzii pridá ďalší účtový mail, nedostane sa sem sám od seba.
  #
  # Kľúč = `action_name` mailera. Hodnota = trieda, ktorú jadro posiela ako druhý argument.
  # Overené na živej inštancii cez `Mailer.instance_method(:issue_add).parameters` —
  # všetky notifikačné akcie majú tvar `(user, objekt)`.
  module Events
    # `attachments_added` dostane POLE príloh. Ukladá sa prvá z nich, nie kontajner
    # (Project/Version/Document): kontajner by pri druhom uploade do toho istého projektu
    # narazil na unique index a druhá notifikácia by nevznikla. Attachment má vlastné id,
    # `acts_as_event` aj `visible?`, takže sa hodí lepšie.
    ATTACHMENTS = 'attachments_added'

    # Reakcia (👍) je jediná udalosť, pri ktorej sa NEUKLADÁ objekt, ktorý poslal mailer.
    # Dôvod: Redmine pri odlajkovaní riadok v `reactions` ZMAŽE a pri opätovnom lajku
    # vytvorí nový s iným id, takže by každé prepnutie vyrobilo ďalšiu notifikáciu o tom
    # istom. Ukladá sa preto objekt, NA KTORÝ sa reagovalo, a v `actor_id` ten, kto lajkol
    # — tá dvojica prepínanie prežije. Viď `Capture#write_reaction`.
    REACTION = 'reaction_added'

    # Na čo sa dá reagovať. Zoznam je pevný, nie odvodený — `source_type` ide cez databázu
    # a loader ho prekladá cez whitelist, nie cez `constantize`.
    REACTABLES = %w[Issue Journal].freeze

    # Naše vlastné pluginy tu nie sú omylom — `redmine_notify_reactions` a `redmine_remind_me`
    # pridávajú akcie `include`-om do jadrového `Mailer`, takže idú cez ten istý `process`.
    # Dostávame ich zadarmo a v tých pluginoch sa nemení ani riadok.
    MAP = {
      'issue_add'            => 'Issue',
      'issue_edit'           => 'Journal',
      'news_added'           => 'News',
      'news_comment_added'   => 'Comment',
      'message_posted'       => 'Message',
      'wiki_content_added'   => 'WikiContent',
      'wiki_content_updated' => 'WikiContent',
      'document_added'       => 'Document',
      ATTACHMENTS            => 'Attachment',
      REACTION               => REACTABLES,
      'remind_me_due'        => 'RemindMeReminder'
    }.freeze

    # Všetky typy, ktoré sa v `source_type` smú objaviť.
    SOURCE_TYPES = MAP.values.flatten.uniq.freeze

    # Preklad `source_type` z databázy na triedu. NIKDY `constantize`:
    #   * `source_type` je síce náš zápis, ale ide cez DB a ta je mimo tohto kódu,
    #   * a hlavne — keby sa odinštaloval `redmine_remind_me`, `constantize` by na osirelých
    #     riadkoch hodil NameError a zhodil by hlavičku KAŽDEJ stránky. Takto sa taký riadok
    #     len ticho preskočí a purge ho zmaže.
    def self.klass_for(source_type)
      return nil unless SOURCE_TYPES.include?(source_type)

      Object.const_defined?(source_type) ? Object.const_get(source_type) : nil
    end

    def self.known?(action_name)
      MAP.key?(action_name.to_s)
    end

    # Vracia vždy pole — `reaction_added` má dva možné typy zdroja (Issue a Journal),
    # ostatné akcie jeden.
    def self.source_types_for(action_name)
      Array(MAP[action_name.to_s])
    end

    # Čo preloadnúť pri vykresľovaní zoznamu. Bez toho by 20 riadkov znamenalo stovky
    # dotazov — `event_title` je v jadre Proc, ktorý siaha na asociácie.
    #
    # Dve pasce, ktoré samotný preload nerieši a ktoré dorieši `Loader`:
    #   * `Journal#event_title` volá `IssueStatus.find_by_id` na každý riadok,
    #   * `Document#event_author` robí `attachments.reorder(...).first` na každý riadok.
    PRELOADS = {
      'Issue'            => [:tracker, :status, :project, :author],
      'Journal'          => [:user, :details, { issue: %i[tracker status project] }],
      'News'             => %i[project author],
      'Comment'          => [:author, { commented: %i[project author] }],
      'Message'          => [:author, :parent, { board: :project }],
      'WikiContent'      => [:author, { page: { wiki: :project } }],
      'Document'         => [:project, :attachments],
      'Attachment'       => %i[author container],
      'RemindMeReminder' => [{ issue: %i[tracker status project] }]
    }.freeze

    def self.preloads_for(source_type)
      PRELOADS[source_type] || []
    end
  end
end
