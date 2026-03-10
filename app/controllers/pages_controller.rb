class PagesController < ApplicationController
  skip_before_action :require_cashtag!, raise: false

  def priosol; end
  def priobousad; end
  def prionet; end
  def zellus; end
end
