// Section: Private

function _iosnativesdk_generateUUID() {
    return Math.random().toString(36).substring(2, 10);
}

const _iosnativesdk_requestPromises = {};

function _iosnativesdk_handleResponse(response) {
    const { id, data, error, errorHTTPResponseBody } = response;
    
    if (_iosnativesdk_requestPromises[id]) {
        if (error) {
            const errorInstance = new NativeSDKError(error, errorHTTPResponseBody);
            _iosnativesdk_requestPromises[id].reject(errorInstance);
            console.log(`Did resolve promise for request ID: ${id}, Request Error: ${error}`);
        } else {
            _iosnativesdk_requestPromises[id].resolve(data);
            console.log(`Did resolve promise for request ID: ${id}, Request Data: ${JSON.stringify(data)}`);
        }
        
        delete _iosnativesdk_requestPromises[id];
    } else {
        console.error(`No promise found for response ID: ${id}`);
    }
}

// Section: Frontent API

class NativeSDKError extends Error {
  constructor(input, errorHTTPResponseBody = null) {
    super(input);
    this.errorHTTPResponseBody = errorHTTPResponseBody;
    if (input.includes(":")) {
      const [name, ...messageParts] = input.split(":");
      this.type = name.trim();
      this.description = messageParts.join(":").trim();
    } else {
      this.type = input;
      this.description = null;
    }
  }
}

/**
 * Sends a request to Swift and returns a promise resolving with the response.
 * 
 * @param {string} [requestType="endpoint"] - The type of the request being sent (default is "endpoint").
 * @param {object} [requestData={}] - Optional data payload for the request (default is an empty object).
 * @returns {Promise<object>} A promise resolving with the response data from Swift. The response data is different depending on the request type.
 */
function sendRequest(requestType = "endpoint", requestData = {}) {
    return new Promise((resolve, reject) => {
        const requestId = _iosnativesdk_generateUUID();
        console.log(`Will perform request ID: ${requestId}, Request Type: ${requestType}, Request Data: ${JSON.stringify(requestData)}`);

        _iosnativesdk_requestPromises[requestId] = { resolve, reject };
        
        const request = {
            id: requestId,
            type: requestType,
            data: requestData,
        };
        
        try {
            window.webkit.messageHandlers._iosnativesdk_requestHandler.postMessage(request);
        } catch (error) {
            delete _iosnativesdk_requestPromises[requestId]; // Clean up on error
            reject(error);
        }
    });
}
