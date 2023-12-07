from flask import Flask
app = Flask(__name__)

@app.route('/')
def main():
  return '<h1>Hello!</h1><p>You are hitting ${{values.application_name}}'

@app.route('/uptime')
def uptime():
  """
  Health check expected by Kubernetes
  """
  return 'OK'

if __name__ == '__main__':
  app.run()