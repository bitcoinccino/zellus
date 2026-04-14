module RateLimitable
  extend ActiveSupport::Concern

  private

  # Simple IP-based rate limiter using Rails.cache
  # Max 5 requests per IP per minute on public payment pages
  def rate_limit!(limit: 5, period: 1.minute)
    key = "rate_limit:#{request.remote_ip}:#{request.path}"
    count = Rails.cache.read(key).to_i

    if count >= limit
      render plain: "Twòp demann. Tanpri eseye ankò nan yon minit.", status: :too_many_requests
      return
    end

    Rails.cache.write(key, count + 1, expires_in: period)
  end
end
