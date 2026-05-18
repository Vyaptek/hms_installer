@echo off
sc create VyaptekRedis binPath= "\"%~1\redis-server.exe\" \"%~1\redis.windows-service.conf\" --service-run" start= auto DisplayName= "Vyaptek HMS Redis"
sc description VyaptekRedis "Redis Cache Server for Vyaptek HMS"
sc start VyaptekRedis
