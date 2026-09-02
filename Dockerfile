FROM tomcat:9.0-jdk11
# Remove default Tomcat webapps
RUN rm -rf /usr/local/tomcat/webapps/*
# Copy your built Maven .war file into Tomcat
COPY target/*.war /usr/local/tomcat/webapps/ROOT.war
EXPOSE 8080
CMD ["catalina.sh", "run"]