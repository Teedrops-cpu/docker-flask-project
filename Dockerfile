# 1. Base image: Python 3.12, slim variant (smaller than the full image)
FROM python:3.12-slim

# 2. Set the working directory inside the container
WORKDIR /app

# 3. Copy only the dependency file first (not the whole app yet)
COPY requirements.txt .

# 4. Install dependencies
RUN pip install --no-cache-dir -r requirements.txt

# 5. Now copy the rest of the application code
COPY . .

# 6. Document which port the container listens on
EXPOSE 5000

# 7. The command that runs when the container starts
CMD ["python", "app.py"]
