FROM eclipse-temurin:25 AS build

WORKDIR /app

COPY pom.xml .
COPY mvnw .
COPY .mvn/ .mvn/

RUN ./mvnw dependency:go-offline --batch-mode --quiet

COPY src/ src/

RUN ./mvnw clean package -DskipTests --batch-mode --quiet

FROM eclipse-temurin:25-jre AS runtime

WORKDIR /app
COPY --from=build /app/target/*.jar app.jar
EXPOSE 8080
EXPOSE 8443
ENTRYPOINT ["java", "-jar", "app.jar"]
