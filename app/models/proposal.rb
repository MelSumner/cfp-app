require 'digest/sha1'

class Proposal < ActiveRecord::Base
  include Proposal::State

  has_many :public_comments, dependent: :destroy
  has_many :internal_comments, dependent: :destroy
  has_many :ratings, dependent: :destroy
  has_many :speakers, -> { order created_at: :asc }, dependent: :destroy
  has_many :taggings, dependent: :destroy
  has_many :proposal_taggings, -> { proposal }, class_name: 'Tagging'
  has_many :review_taggings, -> { review }, class_name: 'Tagging'
  has_many :invitations, dependent: :destroy

  belongs_to :event
  has_one :time_slot
  has_one :program_session
  belongs_to :session_format
  belongs_to :track

  validates :title, :abstract, :session_format, presence: true

  # This used to be 600, but it's so confusing for users that the browser
  # uses \r\n for newlines and they're over the 600 limit because of
  # bytes they can't see. So we give them a bit of tolerance.
  validates :abstract, length: {maximum: 625}
  validates :title, length: {maximum: 60}
  validates_inclusion_of :state, in: valid_states, allow_nil: true, message: "'%{value}' not a valid state."

  serialize :last_change
  serialize :proposal_data, Hash

  attr_accessor :tags, :review_tags, :updating_user
  attr_accessor :video_url, :slide_url

  accepts_nested_attributes_for :public_comments, reject_if: Proc.new { |comment_attributes| comment_attributes[:body].blank? }
  accepts_nested_attributes_for :speakers


  before_create :set_uuid
  before_update :save_attr_history
  after_save :save_tags, :save_review_tags, :touch_updated_by_speaker_at

  scope :accepted, -> { where(state: ACCEPTED) }
  scope :waitlisted, -> { where(state: WAITLISTED) }
  scope :submitted, -> { where(state: SUBMITTED) }
  scope :confirmed, -> { where("confirmed_at IS NOT NULL") }

  scope :soft_accepted, -> { where(state: SOFT_ACCEPTED) }
  scope :soft_waitlisted, -> { where(state: SOFT_WAITLISTED) }
  scope :soft_rejected, -> { where(state: SOFT_REJECTED) }
  scope :working_program, -> { where(state: [SOFT_ACCEPTED, SOFT_WAITLISTED]) }

  scope :unrated, -> { where('id NOT IN ( SELECT proposal_id FROM ratings )') }
  scope :rated, -> { where('id IN ( SELECT proposal_id FROM ratings )') }
  scope :not_withdrawn, -> {where.not(state: WITHDRAWN)}
  scope :not_owned_by, ->(user) {where.not(id: user.proposals.pluck(:id))}
  scope :for_state, ->(state) do
    where(state: state).order(:title).includes(:event, {speakers: :user}, :review_taggings)
  end
  scope :in_track, ->(track) do
    track = nil if track.try(:strip).blank?
    where(track: track)
  end

  scope :emails, -> { joins(speakers: :user).pluck(:email).uniq }

  # Return all reviewers for this proposal.
  # A user is considered a reviewer if they meet the following criteria
  # - They are an teammate for this event
  # AND
  # - They have rated or made a public comment on this proposal, and are not a speaker on this proposal
  def reviewers
    User.joins(:teammates,
                 'LEFT OUTER JOIN ratings AS r ON r.user_id = users.id',
                 'LEFT OUTER JOIN comments AS c ON c.user_id = users.id')
        .where("teammates.event_id = ? AND (r.proposal_id = ? or (c.proposal_id = ? AND c.type = 'PublicComment'))",
               event.id, id, id)
        .where.not(id: speakers.map(&:user_id)).uniq
  end

  # Return all proposals from speakers of this proposal. Does not include this proposal.
  def other_speakers_proposals
    proposals = []
    speakers.each do |speaker|
      speaker.proposals.each do |p|
        if p.id != id && p.event_id == event.id
          proposals << p
        end
      end
    end
    proposals
  end

  def video_url
    proposal_data[:video_url]
  end

  def slides_url
    proposal_data[:slides_url]
  end

  def video_url=(video_url)
    proposal_data[:video_url] = video_url
  end

  def slides_url=(slides_url)
    proposal_data[:slides_url] = slides_url
  end

  def custom_fields=(custom_fields)
    proposal_data[:custom_fields] = custom_fields
  end

  def custom_fields
    proposal_data[:custom_fields] || {}
  end

  def update_state(new_state)
    update(state: new_state)
  end

  def finalize
    update_state(SOFT_TO_FINAL[state]) if SOFT_TO_FINAL.has_key?(state)
  end

  def withdraw
    self.update(state: WITHDRAWN)

    Notification.create_for(reviewers, proposal: self,
                            message: "Proposal, #{title}, withdrawn")
  end

  def draft?
    self.state == SUBMITTED
  end

  def finalized?
    FINAL_STATES.include?(state)
  end

  def confirmed?
    self.confirmed_at.present?
  end

  def to_param
    uuid
  end

  def rate(user, score)
    rating = user.rating_for(self)
    if rating.persisted? && score.blank?
      return rating.destroy ? user.ratings.build(proposal: self) : rating
    end

    rating.score = score
    rating.save
    rating
  end

  def average_rating
    return nil if ratings.empty?
    ratings.map(&:score).inject(:+).to_f / ratings.size
  end

  def standard_deviation
    unless ratings.empty?
      scores = ratings.map(&:score)

      squared_reducted_total = 0.0
      average = scores.inject(:+)/scores.length.to_f

      scores.each do |score|
        squared_reducted_total = squared_reducted_total + (score - average)**2
      end
      Math.sqrt(squared_reducted_total/(scores.length))
    end
  end

  def has_speaker?(user)
    speakers.where(user_id: user).exists?
  end

  def has_invited?(user)
    user.pending_invitations.map(&:proposal_id).include?(id)
  end

  def was_rated_by_user?(user)
    ratings.any? { |r| r.user_id == user.id }
  end

  def tags
    proposal_taggings.to_a.map(&:tag)
  end

  def review_tags
    review_taggings.to_a.map(&:tag)
  end

  def has_reviewer_comments?
    has_public_reviewer_comments? || has_internal_reviewer_comments?
  end

  def update_and_send_notifications(attributes)
    old_title = title
    if update_attributes(attributes)
      field_names = last_change.join(', ')

      Notification.create_for(reviewers, proposal: self,
                              message: "Proposal, #{old_title}, updated [ #{field_names} ]")
    end
  end

  def has_reviewer_activity?
    ratings.present? || has_reviewer_comments?
  end

  def update_without_touching_updated_by_speaker_at(params)
    @dont_touch_updated_by_speaker_at = true
    success = update_attributes(params)
    @dont_touch_updated_by_speaker_at = false
    success
  end

  private

  def save_tags
    if @tags
      update_tags(proposal_taggings, @tags, false)
    end
  end

  def save_review_tags
    if @review_tags
      update_tags(review_taggings, @review_tags, true)
    end
  end

  def update_tags(old, new, internal)
    old.destroy_all
    tags = new.uniq.sort.map do |t|
      {tag: t.strip, internal: internal} if t.present?
    end.compact
    taggings.create(tags)
  end

  def has_public_reviewer_comments?
    public_comments.reject { |comment| speakers.include?(comment.user_id) }.any?
  end

  def has_internal_reviewer_comments?
    internal_comments.reject { |comment| speakers.include?(comment.user_id) }.any?
  end

  def save_attr_history
    if updating_user && updating_user.organizer_for_event?(event) || @dont_touch_updated_by_speaker_at
      # Erase the record of last change if the proposal is updated by an
      # organizer
      self.last_change = nil
    else
      changes_whitelist = %w(pitch abstract details title)
      self.last_change = changes_whitelist & changed
    end
  end

  def set_uuid
    self.uuid = Digest::SHA1.hexdigest([event_id, title, created_at, rand(100)].map(&:to_s).join('-'))[0, 10]
  end

  def touch_updated_by_speaker_at
    touch(:updated_by_speaker_at) unless @dont_touch_updated_by_speaker_at
  end
end

# == Schema Information
#
# Table name: proposals
#
#  id                    :integer          not null, primary key
#  event_id              :integer
#  state                 :string           default("submitted")
#  uuid                  :string
#  title                 :string
#  session_format_id     :integer
#  track_id              :integer
#  abstract              :text
#  details               :text
#  pitch                 :text
#  last_change           :text
#  confirmation_notes    :text
#  proposal_data         :text
#  updated_by_speaker_at :datetime
#  confirmed_at          :datetime
#  created_at            :datetime
#  updated_at            :datetime
#
# Indexes
#
#  index_proposals_on_event_id           (event_id)
#  index_proposals_on_session_format_id  (session_format_id)
#  index_proposals_on_track_id           (track_id)
#  index_proposals_on_uuid               (uuid) UNIQUE
#
