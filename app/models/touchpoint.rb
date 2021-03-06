require 'csv'
class Touchpoint < ApplicationRecord
  include AASM

  belongs_to :form, optional: true
  belongs_to :organization
  has_many :submissions
  has_many :user_roles
  has_many :users, through: :user_roles, :primary_key => "touchpoint_id"

  validates :name, presence: true
  validates :delivery_method, presence: true
  validates :anticipated_delivery_count, numericality: true, allow_nil: true

  validate :omb_number_with_expiration_date

  after_initialize  :check_expired

  before_save :set_uuid

  def self.find_by_short_uuid(short_uuid)
    where("uuid LIKE ?", "#{short_uuid}%").first
  end

  def to_param
    short_uuid
  end

  def short_uuid
    uuid[0..7]
  end

  def omb_number_with_expiration_date
    if omb_approval_number.present? && !expiration_date.present?
      errors.add(:expiration_date, "required with an OMB Number")
    end
    if expiration_date.present? && !omb_approval_number.present?
      errors.add(:omb_approval_number, "required with an Expiration Date")
    end
  end

  DELIVERY_METHODS = [
    "touchpoints-hosted-only",
    "modal",
    "custom-button-modal",
    "inline"
  ]


  aasm do
    state :in_development, initial: true
    state :ready_to_submit_to_PRA # manual
    state :submitted_to_PRA # manual
    state :PRA_approved # manual - adding OMB Numbers
    state :PRA_denied # manual
    state :live # manual
    state :archived # after End Date, or manual


    event :develop do
      transitions from: [:in_development, :ready_to_submit_to_PRA, :submitted_to_PRA, :PRA_approved, :PRA_denied, :live, :archived], to: :in_development
    end
    event :ready_to_submit do
      transitions from: [:in_development, :ready_to_submit_to_PRA, :submitted_to_PRA, :PRA_approved, :PRA_denied, :live, :archived], to: :ready_to_submit_to_PRA
    end
    event :submit do
      transitions from: [:in_development, :ready_to_submit_to_PRA, :submitted_to_PRA, :PRA_approved, :PRA_denied, :live, :archived], to: :submitted_to_PRA
    end
    event :approve do
      transitions from: [:in_development, :ready_to_submit_to_PRA, :submitted_to_PRA, :PRA_approved, :PRA_denied, :live, :archived], to: :PRA_approved
    end
    event :deny do
      transitions from: [:in_development, :ready_to_submit_to_PRA, :submitted_to_PRA, :PRA_approved, :PRA_denied, :live, :archived], to: :PRA_denied
    end
    event :publish do
      transitions from: [:in_development, :ready_to_submit_to_PRA, :submitted_to_PRA, :PRA_approved, :PRA_denied, :live, :archived], to: :live
    end
    event :archive do
      transitions from: [:in_development, :ready_to_submit_to_PRA, :submitted_to_PRA, :PRA_approved, :PRA_denied, :live, :archived], to: :archived
    end
  end

  scope :active, -> { where("id > 0") } # TODO: make this sample scope more intelligent/meaningful

  def send_notifications?
    self.notification_emails.present?
  end

  def deployable_touchpoint?
    self.live?
  end

  # returns javascript text that can be used standalone
  # or injected into a GTM Container Tag
  def touchpoints_js_string
    ApplicationController.new.render_to_string(partial: "components/widget/fba.js", locals: { touchpoint: self })
  end

  def to_csv
    non_flagged_submissions = self.submissions.non_flagged
    return nil unless non_flagged_submissions.present?

    header_attributes = self.hashed_fields_for_export.values
    attributes = self.fields_for_export

    CSV.generate(headers: true) do |csv|
      csv << header_attributes

      non_flagged_submissions.each do |submission|
        csv << attributes.map { |attr| submission.send(attr) }
      end
    end
  end

  def user_role?(user:)
    role = self.user_roles.find_by_user_id(user.id)
    role.present? ? role.role : nil
  end

  # TODO: Refactor into a Report class

  # Generates 1 of 2 exported files for the A11
  # This is a one record metadata file
  def to_a11_header_csv(start_date:, end_date:)
    non_flagged_submissions = self.submissions.non_flagged
    return nil unless non_flagged_submissions.present?

    header_attributes = [
      "submission comment",
      "survey_instrument_reference",
      "agency_poc_name",
      "agency_poc_email",
      "department",
      "bureau",
      "service",
      "transaction_point",
      "mode",
      "start_date",
      "end_date",
      "total_volume",
      "survey_opp_volume",
      "response_count",
      "OMB_control_number",
      "federal_register_url"
    ]

    CSV.generate(headers: true) do |csv|
      submission = non_flagged_submissions.first
      csv << header_attributes
      csv << [
        submission.form.data_submission_comment,
        submission.form.survey_instrument_reference,
        submission.form.agency_poc_name,
        submission.form.agency_poc_email,
        submission.form.department,
        submission.form.bureau,
        submission.form.service_name,
        submission.form.name,
        submission.form.medium,
        start_date,
        end_date,
        submission.form.anticipated_delivery_count,
        submission.form.survey_form_activations,
        non_flagged_submissions.length,
        submission.form.omb_approval_number,
        submission.form.federal_register_url,
      ]
    end
  end

  # Generates the 2nd of 2 exported files for the A11
  # This is a 7 record detail file; one for each question
  def to_a11_submissions_csv(start_date:, end_date:)
    non_flagged_submissions = self.submissions.non_flagged
    return nil unless non_flagged_submissions.present?

    header_attributes = [
      "standardized_question_number",
      "standardized_question_identifier",
      "customized_question_text",
      "likert_scale_1",
      "likert_scale_2",
      "likert_scale_3",
      "likert_scale_4",
      "likert_scale_5",
      "response_volume",
      "notes",
      "start_date",
      "end_date"
    ]

    @hash = {
      answer_01: Hash.new(0),
      answer_02: Hash.new(0),
      answer_03: Hash.new(0),
      answer_04: Hash.new(0),
      answer_05: Hash.new(0),
      answer_06: Hash.new(0),
      answer_07: Hash.new(0)
    }

    # Aggregate likert scale responses
    non_flagged_submissions.each do |submission|
      @hash.keys.each do |field|
        response = submission.send(field)
        if response.present?
          @hash[field][submission.send(field)] += 1
        end
      end
    end

    # TODO: Needs work
    CSV.generate(headers: true) do |csv|
      csv << header_attributes

      @hash.each_pair do |key, values|
        @question_text = "123"
        if key == :answer_01
          question = form.questions.where(answer_field: key).first
          response_volume = values.values.collect { |v| v.to_i }.sum
          @question_text = question.text
          standardized_question_number = 1
        elsif key == :answer_02
          question = form.questions.where(answer_field: key).first
          response_volume = values.values.collect { |v| v.to_i }.sum
          @question_text = question.text
          standardized_question_number = 2
        elsif key == :answer_03
          question = form.questions.where(answer_field: key).first
          response_volume = values.values.collect { |v| v.to_i }.sum
          @question_text = question.text
          standardized_question_number = 3
        elsif key == :answer_04
          question = form.questions.where(answer_field: key).first
          response_volume = values.values.collect { |v| v.to_i }.sum
          @question_text = question.text
          standardized_question_number = 4
        elsif key == :answer_05
          question = form.questions.where(answer_field: key).first
          response_volume = values.values.collect { |v| v.to_i }.sum
          @question_text = question.text
          standardized_question_number = 5
        elsif key == :answer_06
          question = form.questions.where(answer_field: key).first
          response_volume = values.values.collect { |v| v.to_i }.sum
          @question_text = question.text
          standardized_question_number = 6
        elsif key == :answer_07
          question = form.questions.where(answer_field: key).first
          response_volume = values.values.collect { |v| v.to_i }.sum
          @question_text = question.text
          standardized_question_number = 7
        end

        csv << [
          standardized_question_number,
          key,
          @question_text,
          values["1"],
          values["2"],
          values["3"],
          values["4"],
          values["5"],
          response_volume,
          "", # Empty field for the user to enter their own notes
          start_date,
          end_date
        ]
      end

    end
  end

  def fields_for_export
    raise InvalidArgument unless self.form

    self.hashed_fields_for_export.keys
  end

  # TODO: Move to /models/submission.rb
  def hashed_fields_for_export
    raise InvalidArgument unless self.form

    hash = {}

    self.form.questions.map { |q| hash[q.answer_field] = q.text }

    hash.merge({
                 ip_address: "IP Address",
                 user_agent: "User Agent",
                 page: "Page",
                 referer: "Referrer",
                 created_at: "Created At"
    })
  end

  def transitionable_states
    self.aasm.states(permitted: true)
  end

  def all_states
    self.aasm.states
  end

  def check_expired
    if !self.archived? and self.expiration_date.present? and self.expiration_date <= Date.today
      self.id ? self.archive! : self.archive
      Event.log_event(Event.names[:touchpoint_archived],"Touchpoint",self.id,"Touchpoint #{self.name} archived on #{Date.today}") if self.id
    end
  end

  def set_uuid
    self.uuid = SecureRandom.uuid  if !self.uuid.present?
  end

end
