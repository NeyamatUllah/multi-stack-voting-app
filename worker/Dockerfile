# Stage 1: Build
FROM mcr.microsoft.com/dotnet/sdk:8.0.421-bookworm-slim AS build
WORKDIR /src

# Copy the project file and restore dependencies
COPY Worker.csproj .
RUN dotnet restore

# Copy the rest of the source code and build
COPY . .
RUN dotnet publish -c Release -o /app/publish

# Stage 2: Runtime
FROM mcr.microsoft.com/dotnet/runtime:8.0.27-bookworm-slim AS runtime
WORKDIR /app

# Upgrade OS packages to pick up patched libgnutls30 and other fixed CVEs
# hadolint ignore=DL3005,DL3008
RUN apt-get update && \
    apt-get upgrade -y --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

# Create non-root user before COPY so --chown can reference it
RUN addgroup --system appgroup && \
    adduser --system --ingroup appgroup appuser

# Copy published output with ownership set at write time — avoids a separate chown layer
COPY --chown=appuser:appgroup --from=build /app/publish ./

USER appuser

# Set environment variables (can be overridden at runtime)
ENV DB_HOST=db
ENV DB_USERNAME=postgres
ENV DB_PASSWORD=postgres
ENV DB_NAME=postgres
ENV REDIS_HOST=redis

# Define the entry point
ENTRYPOINT ["dotnet", "Worker.dll"]
