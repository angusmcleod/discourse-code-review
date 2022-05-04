# frozen_string_literal: true

module DiscourseCodeReview
  module State::GithubRepoCategories
    GITHUB_REPO_ID = "GitHub Repo ID"
    GITHUB_REPO_NAME = "GitHub Repo Name"
    GITHUB_ISSUES = "Issues"

    class << self
      def ensure_category(repo_name:, repo_id: nil, issues: false)
        ActiveRecord::Base.transaction(requires_new: true) do
          repo_category =
            GithubRepoCategory
              .find_by(repo_id: repo_id)

          repo_category ||=
            GithubRepoCategory
              .find_by(name: repo_name)

          category = repo_category&.category

          if !category && repo_id.present?
            # create new category
            description_key = issues ? "issues_category_description" : "category_description"
            short_name = find_category_name(repo_name, repo_id, issues)

            category = Category.new(
              name: short_name,
              user: Discourse.system_user,
              description: I18n.t("discourse_code_review.#{description_key}", repo_name: repo_name)
            )
            parent_category_id = get_parent_category_id(repo_name, repo_id, issues)
            if parent_category_id.present?
              category.parent_category_id = parent_category_id
            end

            category.save!

            if SiteSetting.code_review_default_mute_new_categories
              existing_category_ids = Category.where(id: SiteSetting.default_categories_muted.split("|")).pluck(:id)
              SiteSetting.default_categories_muted = (existing_category_ids << category.id).join("|")
            end

            repo_category = GithubRepoCategory.new(category_id: category.id)
          end

          if category
            repo_category.repo_id = repo_id
            repo_category.name = repo_name
            repo_category.save! if repo_category.changed?

            category.custom_fields[GITHUB_REPO_ID] = repo_id
            category.custom_fields[GITHUB_REPO_NAME] = repo_name
            category.custom_fields[GITHUB_ISSUES] = issues
            category.save_custom_fields
          end

          category
        end
      end

      def each_repo_name(&blk)
        GithubRepoCategory
          .pluck(:name)
          .each(&blk)
      end

      def get_repo_name_from_topic(topic)
        GithubRepoCategory
          .where(category_id: topic.category_id)
          .first
          &.name
      end

      private

      def get_parent_category_id(repo_name, repo_id, issues)
        parent_category_id = DiscourseCodeReview::Hooks.apply_parent_category_finder(repo_name, repo_id, issues)

        if !parent_category_id && SiteSetting.code_review_default_parent_category.present?
          parent_category_id = SiteSetting.code_review_default_parent_category.to_i
        end

        parent_category_id
      end

      private

      def find_category_name(repo_name, repo_id, issues)
        name = DiscourseCodeReview::Hooks.apply_category_namer(repo_name, repo_id, issues)
        return name if name.present?

        name = repo_name.split("/", 2).last
        name += "-issues" if issues

        if Category.where(name: name).exists?
          name += SecureRandom.hex
        else
          name
        end
      end

      def scoped_categories(issues: false)
        if issues
          Category.where("id IN (SELECT category_id FROM category_custom_fields WHERE name = '#{GITHUB_ISSUES}' and value::boolean IS TRUE)")
        else
          Category
        end
      end
    end
  end
end
