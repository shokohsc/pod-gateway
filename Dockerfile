FROM golang:1.22 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /webhook ./cmd/webhook

FROM scratch
COPY --from=build /webhook /webhook
ENTRYPOINT ["/webhook"]
