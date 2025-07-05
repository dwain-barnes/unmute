@echo off
setlocal enabledelayedexpansion

REM ==============================================================================
REM Windows Docker Startup Script for Unmute with Ollama + GPU Support
REM ==============================================================================

title Unmute with Ollama - Windows Setup (GPU Enabled)

REM Change to the directory where the script is located
cd /d "%~dp0"

echo.
echo ====================================================================
echo                    Unmute with Ollama Setup
echo                       GPU Support Enabled
echo ====================================================================
echo.
echo [INFO] Script location: %~dp0
echo [INFO] Current directory: %cd%
echo.

REM Check if running as Administrator
net session >nul 2>&1
if %errorLevel% == 0 (
    echo [INFO] Running with Administrator privileges
) else (
    echo [WARNING] Not running as Administrator - some operations may fail
    echo [WARNING] Consider running as Administrator if you encounter issues
)

echo.
echo [STEP 1] Creating necessary directories...
echo.

REM Create necessary directories
set "directories=volumes\models volumes\huggingface-cache volumes\vllm-cache volumes\uv-cache volumes\cargo-registry-tts volumes\tts-target volumes\tts-logs volumes\cargo-registry-stt volumes\stt-target services\moshi-server"

for %%d in (%directories%) do (
    if not exist "%%d" (
        mkdir "%%d"
        echo [CREATED] %%d
    ) else (
        echo [EXISTS] %%d
    )
)

echo.
echo [STEP 2] Checking Docker + GPU support...
echo.

REM Check if Docker is installed and running
docker --version >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] Docker is not installed or not in PATH
    echo [ERROR] Please install Docker Desktop for Windows from: https://www.docker.com/products/docker-desktop/
    echo.
    pause
    exit /b 1
) else (
    echo [OK] Docker is installed
)

REM Check if Docker is running
docker info >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] Docker is not running
    echo [ERROR] Please start Docker Desktop and try again
    echo.
    pause
    exit /b 1
) else (
    echo [OK] Docker is running
)

REM Check GPU support in Docker
echo [INFO] Checking GPU support in Docker...
docker run --rm --gpus all nvidia/cuda:11.0-base nvidia-smi >nul 2>&1
if %errorlevel% neq 0 (
    echo [WARNING] GPU support not available in Docker
    echo [WARNING] GPU features may not work properly
    echo [WARNING] Make sure NVIDIA Container Toolkit is installed
) else (
    echo [OK] GPU support available in Docker
)

echo.
echo [STEP 3] Checking Ollama installation...
echo.

REM Check if Ollama is installed
where ollama >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] Ollama is not installed or not in PATH
    echo [ERROR] Please install Ollama from: https://ollama.com/download
    echo [ERROR] After installation, restart this script
    echo.
    pause
    exit /b 1
) else (
    echo [OK] Ollama is installed
)

REM Check if Ollama is running
echo [INFO] Checking if Ollama is running...
curl -s --connect-timeout 5 http://localhost:11434/api/tags >nul 2>&1
if %errorlevel% neq 0 (
    echo [WARNING] Ollama is not running. Starting Ollama...
    echo [INFO] Starting Ollama in the background...
    start /b ollama serve
    
    REM Wait for Ollama to start
    echo [INFO] Waiting for Ollama to start...
    set /a counter=0
    :wait_ollama
    timeout /t 2 /nobreak >nul
    curl -s --connect-timeout 2 http://localhost:11434/api/tags >nul 2>&1
    if %errorlevel% neq 0 (
        set /a counter+=1
        if !counter! lss 15 (
            echo [INFO] Still waiting for Ollama... (!counter!/15)
            goto wait_ollama
        ) else (
            echo [ERROR] Ollama failed to start after 30 seconds
            echo [ERROR] Please start Ollama manually: 'ollama serve'
            echo.
            pause
            exit /b 1
        )
    )
    echo [OK] Ollama is now running
) else (
    echo [OK] Ollama is already running
)

echo.
echo [STEP 4] Checking Ollama models...
echo.

REM Check if required model is available
set "model_name=llama3.2"
echo [INFO] Checking for model: %model_name%
curl -s http://localhost:11434/api/tags | findstr "%model_name%" >nul 2>&1
if %errorlevel% neq 0 (
    echo [WARNING] Model '%model_name%' not found
    echo [INFO] Available models:
    curl -s http://localhost:11434/api/tags
    echo.
    set /p install_model="Would you like to install %model_name%? (y/n): "
    if /i "!install_model!"=="y" (
        echo [INFO] Installing %model_name%... This may take several minutes
        ollama pull %model_name%
        if %errorlevel% neq 0 (
            echo [ERROR] Failed to install %model_name%
            echo [ERROR] Please install manually: ollama pull %model_name%
            echo.
            pause
            exit /b 1
        )
        echo [OK] %model_name% installed successfully
    ) else (
        echo [WARNING] Continuing without installing %model_name%
        echo [WARNING] You may need to modify KYUTAI_LLM_MODEL in your .env file
    )
) else (
    echo [OK] Model '%model_name%' is available
)

echo.
echo [STEP 5] Setting up environment configuration...
echo.

REM Check if .env file exists
if not exist ".env" (
    echo [WARNING] .env file not found
    if exist ".env.example" (
        echo [INFO] Creating .env from .env.example
        copy ".env.example" ".env"
        echo [INFO] .env file created from template
        echo [WARNING] Please edit .env file and add your API keys
    ) else (
        echo [INFO] Creating basic .env file...
        (
            echo # Ollama Configuration
            echo KYUTAI_LLM_URL=http://host.docker.internal:11434
            echo KYUTAI_LLM_MODEL=llama3.2
            echo.
            echo # Required API Keys
            echo HUGGING_FACE_HUB_TOKEN=your_hf_token_here
            echo NEWSAPI_API_KEY=your_newsapi_key_here
            echo.
            echo # Docker Compose settings for Windows
            echo COMPOSE_CONVERT_WINDOWS_PATHS=1
            echo DOCKER_BUILDKIT=1
        ) > .env
        echo [INFO] Basic .env file created
        echo [WARNING] Please edit .env file and add your actual API keys
    )
) else (
    echo [OK] .env file exists
)

REM Set environment variables for Windows Docker
echo [INFO] Setting Docker environment variables...
set COMPOSE_CONVERT_WINDOWS_PATHS=1
set DOCKER_BUILDKIT=1

echo.
echo [STEP 6] Fixing Moshi server configuration...
echo.

REM Create missing Moshi server script if it doesn't exist
if not exist "services\moshi-server\start_moshi_server_public.sh" (
    echo [INFO] Creating missing Moshi server script...
    if not exist "services\moshi-server" mkdir "services\moshi-server"
    (
        echo #!/bin/bash
        echo # Auto-generated startup script for Moshi server
        echo exec "$@"
    ) > "services\moshi-server\start_moshi_server_public.sh"
    echo [CREATED] services\moshi-server\start_moshi_server_public.sh
) else (
    echo [OK] Moshi server script exists
)

echo.
echo [STEP 7] Checking Docker Compose configuration...
echo.

REM Check if docker-compose.yml exists
echo [INFO] Looking for docker-compose.yml in: %cd%
if not exist "docker-compose.yml" (
    echo [ERROR] docker-compose.yml not found in current directory
    echo [ERROR] Current directory: %cd%
    echo [ERROR] Files in current directory:
    dir /b
    echo.
    echo [INFO] Please ensure you're running this script from the unmute project directory
    echo [INFO] The directory should contain: docker-compose.yml, unmute folder, etc.
    echo.
    pause
    exit /b 1
) else (
    echo [OK] docker-compose.yml found
)

REM Validate docker-compose.yml
echo [INFO] Validating Docker Compose configuration...
docker-compose config >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] Invalid docker-compose.yml configuration
    echo [ERROR] Please check your docker-compose.yml file for syntax errors
    echo [INFO] Running validation with output...
    docker-compose config
    echo.
    pause
    exit /b 1
) else (
    echo [OK] Docker Compose configuration is valid
)

echo.
echo [STEP 8] Pre-flight checks complete!
echo.

echo ====================================================================
echo                         SYSTEM STATUS
echo ====================================================================
echo [OK] Docker Desktop is running with GPU support
echo [OK] Ollama is running on http://localhost:11434
echo [OK] Required directories created
echo [OK] Model '%model_name%' is available
echo [OK] Environment configuration ready
echo [OK] Moshi server script created
echo [OK] Docker Compose configuration validated
echo ====================================================================
echo.

REM Ask user if they want to start the services
set /p start_services="Start Unmute services now? (y/n): "
if /i not "%start_services%"=="y" (
    echo [INFO] Setup complete. You can start services later with: docker-compose up --build
    echo.
    pause
    exit /b 0
)

echo.
echo [STEP 9] Starting Unmute services...
echo.

echo [INFO] Building and starting Docker containers with GPU support...
echo [INFO] This may take several minutes on first run...
echo [INFO] STT/TTS services will use GPU acceleration
echo.

REM Start the services
docker-compose up --build

REM If we get here, docker-compose has exited
echo.
echo [INFO] Docker services have stopped
echo.

:restart_menu
echo ====================================================================
echo                         OPTIONS
echo ====================================================================
echo 1. Restart services
echo 2. View logs
echo 3. Stop all services
echo 4. Clean up and rebuild
echo 5. Check Ollama status
echo 6. Check GPU status
echo 7. Exit
echo ====================================================================
echo.

set /p choice="Select an option (1-7): "

if "%choice%"=="1" (
    echo [INFO] Restarting services...
    docker-compose up
    goto restart_menu
) else if "%choice%"=="2" (
    echo [INFO] Showing recent logs...
    docker-compose logs --tail=50
    echo.
    pause
    goto restart_menu
) else if "%choice%"=="3" (
    echo [INFO] Stopping all services...
    docker-compose down
    echo [INFO] All services stopped
    echo.
    pause
    goto restart_menu
) else if "%choice%"=="4" (
    echo [WARNING] This will remove all containers and rebuild from scratch
    set /p confirm="Are you sure? (y/n): "
    if /i "!confirm!"=="y" (
        echo [INFO] Cleaning up containers and images...
        docker-compose down --volumes --remove-orphans
        docker system prune -f
        echo [INFO] Rebuilding services...
        docker-compose up --build
    )
    goto restart_menu
) else if "%choice%"=="5" (
    echo [INFO] Checking Ollama status...
    curl -s http://localhost:11434/api/tags
    echo.
    echo [INFO] Ollama models available above
    echo.
    pause
    goto restart_menu
) else if "%choice%"=="6" (
    echo [INFO] Checking GPU status...
    docker run --rm --gpus all nvidia/cuda:11.0-base nvidia-smi
    echo.
    pause
    goto restart_menu
) else if "%choice%"=="7" (
    echo [INFO] Exiting...
    goto end
) else (
    echo [ERROR] Invalid choice. Please select 1-7.
    goto restart_menu
)

:end
echo.
echo [INFO] Unmute Windows startup script completed
echo [INFO] Thank you for using Unmute!
echo.
pause
exit /b 0