class Staff::ProposalReviewsController < Staff::ApplicationController
  before_action :require_proposal, except: [:index]
  before_action :prevent_self, except: [:index]

  decorates_assigned :proposal, with: Staff::ProposalDecorator
  respond_to :html, :js

  def index
    authorize Proposal, :reviewer_index?
    set_title('Review Proposals')

    proposals = policy_scope(Proposal)
                    .includes(:proposal_taggings, :review_taggings, :ratings,
                              :internal_comments, :public_comments)

    proposals.to_a.sort_by! { |p| [p.ratings.present? ? 1 : 0, p.created_at] }
    proposals = Staff::ProposalDecorator.decorate_collection(proposals)

    render locals: {
             proposals: proposals
           }
  end

  def show
    authorize @proposal, :reviewer_show?
    set_title(@proposal.title)

    rating = current_user.rating_for(@proposal)
    rating.touch unless rating.new_record?

    current_user.notifications.mark_as_read_for_proposal(request.url)

    render locals: { rating: rating }
  end

  def update
    authorize @proposal, :reviewer_update?

    unless @proposal.update_without_touching_updated_by_speaker_at(proposal_review_tags_params)
      flash[:danger] = 'There was a problem saving the proposal.'
    else
      flash[:info] = 'Review Tags were saved for this proposal'
      @proposal.reload
    end
  end

  def rate
    authorize @proposal, :reviewer_rate?

    @rating = @proposal.rate(current_user, rating_params[:score])
    if @rating.errors.present?
      logger.warn("Unable to rate proposal [#{@proposal.id}] for user [#{current_user.id}]: #{@rating.errors.full_messages}")
      render json: @rating.to_json, status: :bad_request
    end
  end

  private

  def proposal_review_tags_params
    params.fetch(:proposal, {}).permit({review_tags: []})
  end

  def rating_params
    params.require(:rating).permit(:score)
  end

end
