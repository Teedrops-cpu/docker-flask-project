# 1. Base image: Python 3.12, slim variant (smaller than the full image)
FROM python:3.12-slim

# 2. Set the working directory inside the container
WORKDIR /app

# 3. Copy only the dependency file first (not the whole app yet)
COPY requirements.txt .

# 4. Install dependencies
#    Runs as root because writing to system site-packages requires it.
RUN pip install --no-cache-dir -r requirements.txt

# 5. Create an unprivileged user to run the application
#    --create-home gives the user a valid HOME; some tooling expects one.
RUN useradd --create-home --shell /bin/bash appuser \
    && chown -R appuser:appuser /app

# 6. Copy the application code, owned by the unprivileged user
COPY --chown=appuser:appuser . .

# 7. Drop privileges. Everything from here on runs as appuser, including CMD.
USER appuser

# 8. Document which port the container listens on
EXPOSE 5000

# 9. Let Docker verify the app is actually serving, not merely running.
#    Uses python rather than curl, which is not installed in the slim image.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:5000/').read()"

# 10. The command that runs when the container starts
CMD ["python", "app.py"]
