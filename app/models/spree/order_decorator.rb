module Spree
  Order.class_eval do
    attr_accessible :store_credit_amount, :remove_store_credits
    attr_accessor :store_credit_amount, :remove_store_credits

    # the check for user? below is to ensure we don't break the
    # admin app when creating a new order from the admin console
    # In that case, we create an order before assigning a user
    before_save :process_store_credit, :if => "self.user.present? && @store_credit_amount"
    after_save :ensure_sufficient_credit, :if => "self.user.present? && !self.completed?"

    validates_with StoreCreditMinimumValidator

    # Finalizes an in progress order after checkout is complete.
    # Called after transition to complete state when payments will have been processed.
    def finalize_with_consume_users_credit!
      finalize_without_consume_users_credit!
      # consume users store credit once the order has completed.
      consume_users_credit
    end
    alias_method_chain :finalize!, :consume_users_credit unless self.method_defined? :finalize_with_consume_users_credit!

    def store_credit_amount
      adjustments.store_credits.sum(:amount).abs
    end

    private

    # credit or update store credit adjustment to correct value if amount specified
    #
    def process_store_credit
      @store_credit_amount = BigDecimal.new(@store_credit_amount.to_s).round(2)

      # store credit can't be greater than order total (not including existing credit), or the user's available credit
      @store_credit_amount = [@store_credit_amount, user.store_credits_total, (total + store_credit_amount.abs)].min

      if @store_credit_amount <= 0
        adjustments.store_credits.destroy_all
      else
        if sca = adjustments.store_credits.first
          sca.update_attributes({:amount => -(@store_credit_amount)})
        else
          # create adjustment off association to prevent reload
          sca = adjustments.store_credits.create(:label => I18n.t(:store_credit) , :amount => -(@store_credit_amount))
        end
      end

      # recalc totals and ensure payment is set to new amount
      update_totals
      
    end

    def consume_users_credit
      return unless completed? and user.present?
      credit_used = self.store_credit_amount

      user.store_credits.each do |store_credit|
        break if credit_used == 0
        if store_credit.remaining_amount > 0
          if store_credit.remaining_amount > credit_used
            store_credit.remaining_amount -= credit_used
            store_credit.save
            credit_used = 0
          else
            credit_used -= store_credit.remaining_amount
            store_credit.update_attribute(:remaining_amount, 0)
          end
        end
      end

    end

    # ensure that user has sufficient credits to cover adjustments
    #
    def ensure_sufficient_credit
      if user.store_credits_total < store_credit_amount
        # user's credit does not cover all adjustments.
        adjustments.store_credits.destroy_all

        update!
      end
    end
  end
end
