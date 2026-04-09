FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /app

# Copy project file and shared source from aspnet-minimal
COPY frameworks/aspnet-minimal_nginx/aspnet-minimal_nginx.csproj .
COPY frameworks/aspnet-minimal_nginx/Program.cs .
COPY frameworks/aspnet-minimal/Handlers.cs .
COPY frameworks/aspnet-minimal/AppData.cs .
COPY frameworks/aspnet-minimal/Models.cs .

RUN dotnet publish -c Release -o out

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --from=build /app/out .
EXPOSE 8080

ENTRYPOINT ["dotnet", "aspnet-minimal_nginx.dll"]
