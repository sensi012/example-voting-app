FROM --platform=${BUILDPLATFORM} mcr.microsoft.com/dotnet/sdk:7.0.410 AS build
ARG TARGETPLATFORM
ARG TARGETARCH
ARG BUILDPLATFORM

WORKDIR /source
COPY *.csproj .
RUN dotnet restore -a $TARGETARCH

COPY . .
RUN dotnet publish -c release -o /app -a $TARGETARCH --self-contained false --no-restore

# app image
FROM mcr.microsoft.com/dotnet/runtime:7.0.20
RUN groupadd -g 1000 appuser && \
    useradd -u 1000 -g appuser -s /bin/sh appuser

WORKDIR /app
COPY --chown=appuser:appuser --from=build /app .

USER appuser
ENTRYPOINT ["dotnet", "Worker.dll"]
