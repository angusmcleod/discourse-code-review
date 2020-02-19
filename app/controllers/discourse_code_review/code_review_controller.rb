# frozen_string_literal: true

module DiscourseCodeReview
  class CodeReviewController < ::ApplicationController
    before_action :ensure_logged_in
    before_action :ensure_staff

    skip_before_action :verify_authenticity_token, only: :webhook
    skip_before_action :ensure_logged_in, only: :webhook
    skip_before_action :ensure_staff, only: :webhook
    skip_before_action :redirect_to_login_if_required, only: :webhook
    skip_before_action :check_xhr, only: :webhook

    def webhook

      if SiteSetting.code_review_github_webhook_secret.blank?
        Rails.logger.warn("Make sure you set a secret up in code_review_github_webhook_secret")
        raise Discourse::InvalidAccess
      end

      request.body.rewind
      body = request.body.read
      signature = OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha1'), SiteSetting.code_review_github_webhook_secret, body)

      if !Rack::Utils.secure_compare("sha1=#{signature}", request.env['HTTP_X_HUB_SIGNATURE'])
        raise Discourse::InvalidAccess
      end

      type = request.env['HTTP_X_GITHUB_EVENT']

      # unique hash for webhook
      # delivery = request.env['HTTP_X_GITHUB_DELIVERY']

      repo = params["repository"]
      repo_name = repo["full_name"] if repo

      if ["commit_comment", "push"].include? type
        client = DiscourseCodeReview.octokit_client
        github_commit_querier = DiscourseCodeReview.github_commit_querier
        repo = GithubRepo.new(repo_name, client, github_commit_querier)
        importer = Importer.new(repo)

        if type == "commit_comment"
          commit_sha = params["comment"]["commit_id"]

          importer.sync_commit_sha(commit_sha)
        elsif type == "push"
          importer.sync_merged_commits do |commit_hash|
            if SiteSetting.code_review_approve_approved_prs
              DiscourseCodeReview
                .github_pr_syncer
                .apply_github_approves(repo_name, commit_hash)
            end
          end
        end
      end

      if type == "commit_comment"
        syncer = DiscourseCodeReview.github_pr_syncer
        git_commit = params["comment"]["commit_id"]

        syncer.sync_associated_pull_requests(repo_name, git_commit)
      end

      if ["pull_request", "issue_comment", "pull_request_review", "pull_request_review_comment"].include? type
        syncer = DiscourseCodeReview.github_pr_syncer

        issue_number =
          params['number'] ||
          (params['issue'] && params['issue']['number']) ||
          (params['pull_request'] && params['pull_request']['number'])

        syncer.sync_pull_request(repo_name, issue_number)
      end

      render plain: '"ok"'
    end

    def followup
      topic = Topic.find_by(id: params[:topic_id])

      DiscourseCodeReview::CommitApprovalStateService.followup(
        topic,
        current_user
      )

      render_next_topic(topic.category_id)
    end

    def approve
      topic = Topic.find_by(id: params[:topic_id])

      if !SiteSetting.code_review_allow_self_approval && topic.user_id == current_user.id
        raise Discourse::InvalidAccess
      end

      DiscourseCodeReview::CommitApprovalStateService.approve(
        topic,
        [current_user]
      )

      render_next_topic(topic.category_id)
    end

    protected

    def render_next_topic(category_id)

      category_filter_sql = <<~SQL
        category_id NOT IN (
          SELECT category_id
          FROM category_users
          WHERE user_id = :user_id AND
            notification_level = :notification_level
        )
      SQL

      next_topic = Topic
        .joins(:tags)
        .joins("LEFT OUTER JOIN topic_users ON (topics.id = topic_users.topic_id AND topic_users.user_id = #{current_user.id})")
        .where('tags.name = ?', SiteSetting.code_review_pending_tag)
        .where('topics.user_id <> ?', current_user.id)
        .where(
          category_filter_sql,
          user_id: current_user.id,
          notification_level: CategoryUser.notification_levels[:muted]
        )
        .order('case when last_read_post_number IS NULL then 0 else 1 end asc', "case when category_id = #{category_id.to_i} then 0 else 1 end asc", 'bumped_at desc')
        .first

      url = next_topic&.relative_url

      render json: {
        next_topic_url: url
      }
    end

  end
end
