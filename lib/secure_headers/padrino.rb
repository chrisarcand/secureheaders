module SecureHeaders
  module Padrino
    class << self
      ##
      # Main class that register this extension.
      #
      def registered(app)
        app.helpers SecureHeaders::InstanceMethods
      end
      alias_method :included, :registered
    end
  end
end
