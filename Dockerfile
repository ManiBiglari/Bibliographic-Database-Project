FROM apache/airflow:2.6.2

# Switch to root user to install necessary tools
USER root

# Install nano or other required tools
RUN apt-get update && apt-get install -y nano

# Switch back to airflow user
USER airflow

# Set environment variables for admin credentials
ENV AIRFLOW_USERNAME=biglari.mani@gmail.com \
    AIRFLOW_PASSWORD=123456 \
    AIRFLOW_FIRSTNAME=Mani \
    AIRFLOW_LASTNAME=Biglari \
    AIRFLOW_ROLE=Admin \
    AIRFLOW_EMAIL=biglari.mani@gmail.com

# Initialize the database and create the admin user
RUN airflow db init && \
    airflow users create \
        --username $AIRFLOW_USERNAME \
        --password $AIRFLOW_PASSWORD \
        --firstname $AIRFLOW_FIRSTNAME \
        --lastname $AIRFLOW_LASTNAME \
        --role $AIRFLOW_ROLE \
        --email $AIRFLOW_EMAIL