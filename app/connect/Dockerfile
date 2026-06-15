FROM confluentinc/cp-kafka-connect-base:7.5.0

# Install the Couchbase Kafka Connector from Confluent Hub
USER root
RUN confluent-hub install --no-prompt couchbase/kafka-connect-couchbase:4.3.6

# Switch back to the default user
USER appuser
